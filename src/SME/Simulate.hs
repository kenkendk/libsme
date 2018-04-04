{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | SME network simulator

module SME.Simulate (simulate) where

import           Control.Exception                 (throw)
import           Control.Monad                     (foldM, forM, forM_,
                                                    mapAndUnzipM, mapM_,
                                                    replicateM, unless, void,
                                                    when, zipWithM)
import           Data.Bits
import           Data.IORef                        (IORef, newIORef, readIORef,
                                                    writeIORef)
import           Data.List                         (nub)
import           Data.List.NonEmpty                (NonEmpty (..))
import qualified Data.List.NonEmpty                as N
import           Data.Maybe                        (catMaybes, fromMaybe)

import           Control.Concurrent.Async          (async, mapConcurrently,
                                                    wait)
import           Control.Monad.Except              (MonadError)
import           Control.Monad.Extra               (mapMaybeM)
import           Control.Monad.IO.Class            (MonadIO, liftIO)
import           Control.Monad.State               (MonadState, get, gets,
                                                    modify)
import           Data.Graph.Inductive.Graph        (LNode, lab, mkGraph,
                                                    prettyPrint)
import           Data.Graph.Inductive.PatriciaTree (Gr)
import           Data.Graph.Inductive.Query.DFS    (isConnected, scc, topsort)
import qualified Data.HashMap.Strict               as M
import           Data.Loc                          (noLoc)

import           Language.SMEIL.Syntax
import           SME.API
import           SME.CTypes
import           SME.Error
import           SME.Representation

import           Debug.Trace
import           Text.Show.Pretty                  (ppShow)

-- import SME.APITypes

type Env = BaseEnv Void
type DefType = BaseDefType SimExt
type TopDef = BaseTopDef SimExt
type SimEnv = BaseEnv SimExt

newtype SimM a = SimM
  { unSimM :: ReprM IO SimExt a
  } deriving ( Functor
             , Applicative
             , Monad
             , MonadState SimEnv
             , MonadError TypeCheckErrors
             , MonadIO
             )

instance (MonadRepr SimExt) SimM where
  lookupDef' r = do
    ti <- curEnvIdent
    go
      (trace
         ("Lookup called with " ++ show (refOf r) ++ " context " ++ show ti)
         (refOf r))
    -- Three cases.
    -- Case one: Single name [Ident] is found in local scope. Return that
    -- Case two: First name [Ident, ..] refers to a bus in local scope. Return
    -- that.
    -- Case three: Name [Ident, ...] refers to a top-level name. Switch
    -- scope, remaining name compounds should fall into previous cases
    where
      go (i :| []) = do
        d <- getCurEnv
        traceM ("Symbol table " ++ show (nameOf d))
        res <- lookupEx i (symTable d)
        return ([], res)
      go (i :| is) = do
        d <- getCurEnv
        case M.lookup (toString i) (symTable d) of
          Just lookupRes ->
            case lookupRes of
              b@BusDef {} -> pure (is, b)
              inst@InstDef {} -> pure (is, inst)
              ParamDef {paramType = BusPar {..}}
                --trace "GOt back ParamDef" $
               ->
                case ref of
                  (_ :| []) ->
                    throw $
                    InternalCompilerError "Bus reference is a single name"
                  (r' :| rs') -> withScope r' (go (N.fromList (rs' ++ is)))
              _
              -- If first name component doesn't resolve to a possible compound
              -- name in current scope, it probably refers to a top-level
              -- construct, so we look again in that
               -> trace "lookup recursing" $ withScope i (go (N.fromList is))
          Nothing ->
            trace "lookup recursing2" $ withScope i (go (N.fromList is))


newtype InstGraph = InstGraph
  { unInstGraph :: Gr Ident Ident
  }

newtype ProcGraph = ProcGraph
  { unProcGraph :: Gr (IORef ProcInst) String --(IORef BusInst)
  }


data SimExt
  = EnvExt { labelSource :: !Int
           , curVtable   :: VTable
           , links       :: [ProcLink]
           , puppetMode  :: Bool
           , apiPtr      :: SmeCtxPtr
           -- ^ Set to true if we are run as a library
           }
           --, netGraph    ::  NetGraph}
  | ProcTabExt { nodeId             :: Int
               , uniqueBusInstances :: Int -- TODO: add unique buses here
                }
  | NetTabExt --valueTab :: M.HashMap String Value
     { --instTab :: M.HashMap Ident ProcInst
      nodeId  :: Int }
  | InstExt { nodeId :: Int }
  | EmptyExt

instance Extension SimExt where
  emptyExt = EmptyExt
  topExt = ext :: TopDef -> SimExt
  defExt = ext :: DefType -> SimExt
  envExt = ext :: SimEnv -> SimExt

data BusChan
  = LocalChan { name       :: Ident
              , maxVal     :: IORef Value
              , localRead  :: IORef Value
              , localWrite :: IORef Value }
  | ExternalChan { name     :: Ident
                 , maxVal   :: IORef Value
                 , extWrite :: ValuePtr
                 , extRead  :: ValuePtr }
  deriving (Eq)

newtype BusInst  = BusInst
  { chans :: M.HashMap Ident BusChan
  --, ref   :: Ref -- ^Reference to the bus that this was instantiated from
  } deriving (Eq)

-- data ParamVal

-- data ParamVal = ParamVal
--                 { IORef
--  }

data InstState = Phantom | Actual
  deriving (Eq, Show)

data ProcInst = ProcInst
  { instState   :: InstState
  --, params    :: [(Ref, ParamVal)]
  , valueTab    :: VTable
  , stmts       :: [Statement]
  , instNodeId  :: Int
  , synchronous :: Bool
  , fromEnt     :: Ident
  }
  deriving (Show, Eq)

-- TODO: Using this type for the simulation processes actually isn't such a bad
--idea.
-- type RunM = StateT ProcInst IO

type VTable =  M.HashMap Ident SimRef

data SimRef
  = MutVal Value
  | ConstVal Value
  | InstVal ProcInst
  | BusVal BusInst
  deriving (Eq)

instance Show SimRef where
  show (BusVal _)   = "BusVal"
  show (ConstVal v) = show v
  show (MutVal v)   = show v
  show (InstVal v)  = show v

-- | Runs a ProcInst and saves its modified vtable
runProcess :: ProcInst -> SimM ProcInst
runProcess p@ProcInst {..} = do
  (vtab, _) <- withVtable valueTab $ mapM_ evalStm stmts
  return $ p {valueTab = vtab}

-- | Evaluates a statement
evalStm :: Statement -> SimM ()
evalStm Assign {..} = do
  r <- evalExpr val
  setValueVtab (refOf dest) r
evalStm If {..} = do
  c <- evalCondPair cond body
  mapM_ (uncurry evalCondPair) elif
  case els of
    Nothing -> return ()
    Just ss -> unless c (mapM_ evalStm ss)
  where
    evalCondPair e ss = do
      c <-
        evalExpr e >>= \case
          (BoolVal v) -> pure v
          _ -> error "Type error in if"
      when c (mapM_ evalStm ss)
      return c

-- | Evaluates an expression
evalExpr :: Expr -> SimM Value
evalExpr Binary {..} = do
  l <- evalExpr left
  r <- evalExpr right
  return (evalBinOp binOp l r)
evalExpr PrimName {..} = do
  getValueVtab (refOf name)
evalExpr PrimLit {..} =
  pure $ toValue lit


evalBinOp :: BinOp -> Value -> Value -> Value
evalBinOp op (IntVal i) (IntVal j) =
  IntVal $ numBinOp op i j
--evalBinOp

numBinOp :: (Num a) => BinOp -> (a -> a -> a)
numBinOp PlusOp {}  = (+)
numBinOp MinusOp {} = (-)
numBinOp MulOp {}   = (*)

--boolBinOp :: (Eq a, Ord a) => BinOp -> (a->a->Bool)

propagateBus :: BusInst -> SimM ()
propagateBus BusInst {..} = do
  let vs = M.elems chans
  forM_
    vs
    (\case
        LocalChan {localRead = readRef, localWrite = writeRef, name = name} ->
          liftIO $
          -- TODO: Calculate max value
          do
            traceM ("Bus looks like " ++ show name)
            rw <- readIORef writeRef
            rv <- readIORef readRef
            writeIORef readRef rw
            putStrLn ("Bus read value was " ++ show rv))

-- numBinOp AndOp{}    = (.&.)
-- numBinOp DivOp{}    = (/)
--numBinOp EqOp{}     = (==)
--numBinOp ConOp{}    = (||)
--numBinOp DisOp{}    = (&&)

--boolBinOp

-- data Value a
--   = SimpleV (SimpleVal a)
--   | ArrayVal Int a

-- newtype SimpleVal a = SimpleVal a
-- data ArrayVal a = ArrayVal Int [a]

--data family Val a where

-- type family Val a where
--   Val Integer = SimpleVal Int
--   Val Bool = SimpleVal Bool
--   --Val [a] = ArrayVal a

-- instance


--binOpFun :: BinOp -> (a -> a -> a)
--binOpFun AndOp{} = (.&.)
-- binOpFun ConOp{} = (||)
-- binOpFun DivOp{} = (/)
-- binOpFun EqOp{}  = (==)
-- binOpFun DisOp{} = (&&)
-- binOpFun GeqOp{} =
-- binOpFun GtOp{} =
-- binOpFun LeqOp{} =

 -- binOpFun LtOp{} =
-- binOpFun MinusOp{} =
-- binOpFun ModOp{} =
-- binOpFun MulOp{} =
-- binOpFun NeqOp{} =
  -- binOpFun OrOp{} =
--binOpFun PlusOp{} = (+)
-- binOpFun SllOp{} =
-- binOpFun SrlOp{} =
-- binOpFun XorOp{} =

-- | Returns a new and globally unique integer every time its called.
getFreshLabel :: SimM Int
getFreshLabel = do
  curEnv <- get
  let curExt = ext (curEnv :: SimEnv)
      nextId = labelSource curExt
  modify (\x -> x {ext = curExt {labelSource = nextId + 1}} :: SimEnv)
  return nextId

-- | Assign a unique label for every instance. Used for graph construction.
labelInstances :: SimM ()
labelInstances = mapUsedTopDefsM_ go
  where
    go ProcessTable {..} = do
      symTab' <- mapM go' symTable
      newLab <- getFreshLabel
      updateTopDef
        procName
        (\x -> x {symTable = symTab', ext = ProcTabExt {nodeId = newLab}})
    go NetworkTable {..} = do
      symTab' <- mapM go' symTable
      newLab <- getFreshLabel
      updateTopDef
        netName
        (\x ->
           x
           { symTable = symTab'
           , ext = NetTabExt {nodeId = newLab} ---, valueTab = M.empty}
           })
    go' i@InstDef {} = do
      newLab <- getFreshLabel
      return ((i {ext = InstExt {nodeId = newLab}}) :: DefType)
    go' i = return i

class ToValue a where
  toValue :: a -> Value

instance {-# OVERLAPPING #-} ToValue Literal where
  toValue l@LitInt {..} = IntVal intVal
  -- FIXME: This calls for changing the representation of floating point values in
  -- the AST to something completely accurate.
  toValue LitFloat {}   = undefined
  toValue LitArray {}   = undefined
  toValue LitString {}  = undefined
  toValue LitTrue {}    = BoolVal True
  toValue LitFalse {}   = BoolVal False

instance {-# OVERLAPPABLE #-} (Integral a) => ToValue a where
  toValue v = IntVal $ fromIntegral v

apiCallWrap :: (SmeCtxPtr -> f) ->  SimM f
apiCallWrap fun = do
  ctx <- apiPtr <$> gets (ext :: SimEnv -> SimExt)
  return $ fun ctx

-- apiCallWrap3 ::
--      (MonadIO m, MonadIO n) => (SmeCtxPtr -> a -> b -> m c) -> a -> b -> n c
-- apiCallWrap3 = undefined

mkBusInst :: Bool -> Ident -> BusShape -> SimM BusInst
mkBusInst exposed n bs = do
  busFun <- apiCallWrap mkExtBus
  chans <-
    puppetMode <$> gets (ext :: SimEnv -> SimExt) >>= \case
      True ->
        liftIO $ do
          busPtr <- busFun (toString n) -- liftIO $ apiCallWrap $ busFun (toString n)
          toExtChans exposed busPtr bs
      False -> liftIO $ toBusChans bs
  return $ BusInst (M.fromList chans)
  where
    toExtChans :: Bool -> BusPtr -> BusShape -> IO [(Ident, BusChan)]
    toExtChans pup bptr bs' =
      mapM
        (\case
           (i, (Typed ty, lit)) ->
             let defVal = fromMaybe (toValue (0 :: Integer)) (toValue <$> lit)
             in (i, ) <$>
                if pup
                  then do
                    chan <- mkExtChan bptr (toString i) ty
                    ExternalChan i <$> newIORef defVal
                                   <*> pure (writePtr chan)
                                   <*> pure (readPtr chan)
                  else LocalChan i <$> newIORef defVal
                                   <*> newIORef defVal
                                   <*> newIORef defVal
           _ -> error " Illegal bus chan")
        (unBusShape bs')
    toBusChans :: BusShape -> IO [(Ident, BusChan)]
    toBusChans bs' =
      mapM
        (\(i, (_ty, lit)) -- TODO: make this type safe
          ->
           let defVal = fromMaybe (toValue (0 :: Integer)) (toValue <$> lit)
           in (i, ) <$>
              (LocalChan i <$> newIORef defVal
                           <*> newIORef defVal
                           <*> newIORef defVal))
        (unBusShape bs')

-- | Creates a new vtable @ds@ from a list of definitions, adding to table
-- passed as 'vtab'
mkVtable :: [DefType] -> VTable -> SimM VTable
mkVtable ds vtab = foldM go vtab ds
  where
    go m VarDef {..} = return $ M.insert varName (MutVal $ toValue varVal) m
    go m ConstDef {..} =
      return $ M.insert constName (ConstVal $ toValue constVal) m
    go m EnumFieldDef {..} =
      return $ M.insert fieldName (ConstVal $ toValue fieldValue) m
    go m BusDef {..} = do
      bus <- mkBusInst isExposed busName busShape
      return $ M.insert busName (BusVal bus) m
    go m _ = return m

-- | Checks for cycles in the instantiation graph by calculating the Strongly
-- Connected Components (SCC) of the graph. Cycles are indicated by the presence
-- of SCCs consisting of more than one node.
ensureAcyclic :: InstGraph -> SimM ()
ensureAcyclic g =
  case filter ((> 1) . length) (scc (unInstGraph g)) of
    [] -> return ()
  -- TODO: Better error message with line numbers
    a ->
      let labs = (map . map) (lab (unInstGraph g)) a
          labs' = (map . map) (fromMaybe (Ident "unknown" noLoc)) labs
      in throw $
         InternalCompilerError
           ("Instantiation cycles formed by entities " ++
            unwords (map show labs'))

-- | Returns a list of processes that is instantiated from a process.
instantiates :: Ident -> [DefType] -> SimM [LNode Ident]
instantiates instantiator = mapMaybeM go
  where
    go InstDef {..} = do
      td <- lookupTopDef instantiated
      when (instantiator == instantiated) $
        throw $ InternalCompilerError "Entity cannot instantiate itself"
        -- TODO: Better error
      return $ Just (nodeId (topExt td), instantiated)
    go _ = return Nothing

-- | Finds the entity that instantiation should start from. Generates the
-- instantiation graph and ensures that it is acyclic. The returned element is
-- the first element obtained by topologically sorting the nodes of the graph.
getNetworkEntry :: SimM Ident
getNetworkEntry = do
  edges' <- concat . nub <$> mapUsedTopDefsM go
  let nodes' = concatMap (\(e1, e2) -> [e1, e2]) edges'
      edges'' =
        map
          (\((n1, s1), (n2, s2)) -> (n1, n2, s1 <> Ident "_" noLoc <> s2))
          edges'
      graph = InstGraph $ mkGraph nodes' edges''
      instOrder = topsort (unInstGraph graph)
  unless (not (null instOrder)) $
    throw $ InternalCompilerError "Network contains no processes"
  liftIO $ prettyPrint (unInstGraph graph)
  liftIO $ print $ isConnected (unInstGraph graph)
  liftIO $ print $ topsort (unInstGraph graph)
  liftIO $ print $ scc (unInstGraph graph)
  ensureAcyclic graph
  return $
    fromMaybe (Ident "__unknown" noLoc) $
    lab (unInstGraph graph) $ head instOrder
  where
    go a = do
      let symtab = symTable a
      insts <- instantiates (nameOf a) (M.elems symtab)
      return $ map ((nodeId (topExt a), nameOf a), ) insts

withVtable :: VTable -> SimM a -> SimM (VTable, a)
withVtable vtab act = do
  e <- gets (ext :: SimEnv -> SimExt)
  let prev = curVtable e
  modify (\x -> x {ext = e {curVtable = vtab}} :: SimEnv)
  res <- act
  e' <- gets (ext :: SimEnv -> SimExt)
  modify (\x -> x {ext = e' {curVtable = prev}} :: SimEnv)
  return (curVtable e', res)

withVtable_ :: VTable -> SimM a -> SimM a
withVtable_ vtab act = snd <$> withVtable vtab act

getCurVtable :: SimM VTable
getCurVtable = curVtable <$> gets (ext :: SimEnv -> SimExt)

addCurVtable :: Ident -> SimRef -> SimM ()
addCurVtable i r = do
  vtab <- getCurVtable
  putCurVtable $ M.insert i r vtab

putCurVtable :: VTable -> SimM ()
putCurVtable vtab = do
  e <- gets (ext :: SimEnv -> SimExt)
  modify (\x -> x {ext = e {curVtable = vtab}} :: SimEnv)

addLink :: ProcLink -> SimM ()
addLink l = do
  e <- gets (ext :: SimEnv -> SimExt)
  let ls = links e
  modify (\x -> x {ext = e {links = l:ls}} :: SimEnv)

getLinks :: SimM [ProcLink]
getLinks = links <$> gets (ext :: SimEnv -> SimExt)

lookupCurVtable :: Ident -> SimM (Maybe SimRef)
lookupCurVtable i = do
  e <- gets (ext :: SimEnv -> SimExt)
  traceM $ "Cur Vtable is " ++ show (curVtable e)
  return $ M.lookup i (curVtable e)
    -- Nothing -> return Nothing
    -- v       -> return v

lookupCurVtableE :: Ident -> SimM SimRef
lookupCurVtableE i = do
  traceM ("LoockupCurVtaleE called with " ++ show i)
  lookupCurVtable i >>= \case
    Just v -> return v
    Nothing -> throw $ InternalCompilerError "Undefined name during simulation"

setInVtab :: Ident -> SimRef -> SimM ()
setInVtab i v = getCurVtable >>= pure . M.insert i v >>= putCurVtable

getInVtab ::  Ident -> SimM SimRef
getInVtab i =
  (M.lookup i <$> getCurVtable) >>= \case
    Just v -> pure v
    Nothing -> error "Value not found"

setValueVtab :: Ref -> Value -> SimM ()
setValueVtab (i :| []) v' =
  getInVtab i >>= \case
    MutVal _ -> setInVtab i $ MutVal v'
    BusVal _ -> error "bus as value"
    _ -> error "immutable value"
  --setInVtab i =<< valToSimRef v
setValueVtab (i :| [i2]) v' =
  getInVtab i >>= \case
    BusVal v -> liftIO $ setBusVal i2 v v'
    _ -> error "compund name not a bus"
setValueVtab _ _ = throw $ InternalCompilerError "Compound names not supported"

getValueVtab :: Ref -> SimM Value
getValueVtab (i :| []) =
  getInVtab i >>= \case
    MutVal v -> pure v
    ConstVal v -> pure v
    _ -> error "not readable"
getValueVtab (i :| [i2]) =
  getInVtab i >>= \case
    BusVal v -> liftIO $ getBusVal i2 v
    _ -> error "Only buses are accessible through compound names"
getValueVtab _ = throw $ InternalCompilerError "Compound names not supported"

-- valAToSimRef :: Value -> SimM SimRef
-- valToSimRef = undefined

-- TODO: Maybe replace these with Storable instances for BusChan

setBusVal :: Ident -> BusInst -> Value -> IO ()
setBusVal i BusInst {..} v =
  case M.lookup i chans of
    Just LocalChan {localWrite = write}  -> writeIORef write v
    Just ExternalChan {extWrite = write} -> poke write v
    Nothing                              -> error "undefined bus channel"

getBusVal :: Ident -> BusInst -> IO Value
getBusVal i BusInst {..} =
  case M.lookup i chans of
    Just LocalChan {localRead = readEnd}  -> readIORef readEnd
    Just ExternalChan {extRead = readEnd} -> peek readEnd
    Nothing                               -> error "undefined bus channel"

-- | Converts a simulator value reference to a value.
getValue :: SimRef -> SimM Value
getValue (MutVal v)   = return v
getValue (ConstVal v) = return v

evalConstExpr :: Expr -> SimM Value
evalConstExpr PrimLit {..} = return $ toValue lit
evalConstExpr PrimName {name = Name {..}} = case base of
  IdentName {..} -> getValue =<< lookupCurVtableE ident
  ArrayAccess {} -> undefined
    -- do
    -- lookupCurVtable ident >>= \case
    --   ArrayVal {} -> error "Arrays not implemented"

-- mkInitialVtable :: [(Ident, SimRef)] -> VTable
-- mkInitialVtable = M.fromList

-- getBusInstRef :: Ref -> SimM (IORef BusInst)
-- getBusInstRef (b :| _) = do
--   e <- gets (ext :: SimEnv -> SimExt)
--   case M.lookup b (curVtable e) of
--     Just (BusVal r) -> return r
--     Nothing -> throw $ InternalCompilerError "Undefined bus during simulation"


--getBusReference

-- TODO: Normalize the SMEIL code by rewriting it such that direct references to
-- top-level entity definitions are transformed such that the anonymous
-- instances are passed either as input or output parameters to the
-- processes. As a first attempt. Focus only on implementing code generation for
-- programs like in the final form of addone.sme, since that is similar to the
-- normalized form that we want to end up with.

newtype ProcLink = ProcLink (Int, Int, String, BusInst)

data InstTree = InstTree
  { node  :: [ProcInst]
  -- ^ Contains a bus connection
  , leafs :: [InstTree]
  }
  deriving (Eq, Show)

instance Semigroup InstTree where
  (InstTree na ca) <> (InstTree nb cb) = InstTree (na <> nb) (ca <> cb)

instance Monoid InstTree where
  mempty = InstTree [] []

flattenInstTree :: InstTree -> [ProcInst]
flattenInstTree (InstTree n []) = n
flattenInstTree (InstTree n c)  = n ++ concatMap flattenInstTree c

-- | Looks up the bus value corresponding to a bus reference and also returns
-- the instance id for the bus that the process in declared in.
resolveBusParam :: Ref -> SimM (Int, BusInst)
resolveBusParam = go 0
  -- FIXME: In some cases we will actually get a bus back from a single name. In
  -- this case, the node reference returned will be invalid
  where
    go n (r :| []) =
      lookupCurVtableE r >>= \case
        BusVal res -> return (n, res)
        _ -> throw $ InternalCompilerError "Expected bus"
    go _ (r :| rs) =
      lookupCurVtableE r >>= \case
        InstVal instv
        --inst <- liftIO $ readIORef r
         -> withVtable_ (valueTab instv) $ go (instNodeId instv) (N.fromList rs)
        _ -> throw $ InternalCompilerError "Expected instance"

-- | Entity instantiation function. Recursively walks through the instantiation
-- hierachy. Takes a pre-populated symbol table and an entity as argument
instEntity :: VTable -> TopDef -> SimM InstTree
instEntity st NetworkTable {netName = name, symTable = symTable} = do
  let symtab = M.elems symTable
  vtab <- mkVtable symtab st
  traceM $ "Made symtab: " ++ show vtab
  withVtable_ vtab $ withScope name $ processInstDefs symtab
instEntity st ProcessTable {stms = stms, procName = name, symTable = symTable} = do
  let symtab = M.elems symTable
  vtab <- mkVtable symtab st
  instTree <- withVtable_ vtab $ withScope name $ processInstDefs symtab
  --vtab <- mkVtable (M.elems symTable) (mkInitialVtable paramVals)
  newLab <- getFreshLabel
  let inst =
        ProcInst
        { instState = Phantom
        , valueTab = vtab
        , stmts = stms
        , instNodeId = newLab
        , fromEnt = name
        , synchronous = False -- TODO
        }
  return $ instTree {node = [inst]}

processInstDefs :: [DefType] -> SimM InstTree
processInstDefs dt = do
  (instDefs, insts) <- unzip . catMaybes <$> mapM mkInst dt
  let (InstTree myInsts leafs) = mconcat insts
  mapM_ (uncurry addCurVtable) (zip instDefs (map InstVal myInsts))
  myInsts' <- mapM wireInst (zip instDefs myInsts)
  let instTree = InstTree myInsts' leafs
  return (InstTree [] [instTree])

mkInst :: DefType -> SimM (Maybe (Ident, InstTree))
mkInst InstDef { instantiated = instantiated
               , instDef = Instance {params = actual}
               , instName = instName
               }
  -- TODO: Give instances names of the format
  -- process_name-inst_name-bus_name-chan_name (This will not be unique in
  -- the case of recursive instances). We can get the top-level-entity since
  -- we are in its scope (see withScope). We also know the name of its
  -- instances (right here) and the buses since we instantiate them here
 = do
  inst <- lookupTopDef instantiated
  let parList = (params :: TopDef -> ParamList) inst
  paramVals <-
    catMaybes <$>
    zipWithM
      (\(parName, parType) (_, parVal) ->
         case parType of
           ConstPar _ ->
             Just . (parName, ) <$> (MutVal <$> evalConstExpr parVal)
           BusPar {} -> pure Nothing)
      parList
      actual
  Just . (instName, ) <$> instEntity (M.fromList paramVals) inst
mkInst _ = pure Nothing

wireInst :: (Ident, ProcInst) -> SimM ProcInst
wireInst (instDefName, procInst@ProcInst {instNodeId = myNodeId}) = do
  traceM "Entered wireInst"
  lookupDef instDefName >>= \case
    InstDef { instantiated = instantiated
            , instDef = Instance {params = actual}} -> do
      inst <- lookupTopDef instantiated
      let parList = (params :: TopDef -> ParamList) inst
      paramVals <-
        catMaybes <$>
        zipWithM
          (\(parName, parType) (_, parVal) ->
             case parType of
               ConstPar _ -> pure Nothing
               BusPar {..} -> do
                 (nid, ref') <- resolveBusParam localRef
                 case busState of
                   Input -> addLink (ProcLink (myNodeId, nid, "foo", ref'))
                   Output -> addLink (ProcLink (nid, myNodeId, "foo", ref'))
                   _ -> throw $ InternalCompilerError "BusState invalid here"
                 return $ Just (parName, BusVal ref'))
          parList
          actual
      let vtab = (valueTab :: ProcInst -> VTable) procInst
          vtab' = foldr (uncurry M.insert) vtab paramVals
      return $ procInst {instState = Actual, valueTab = vtab'}
    _ -> throw $ InternalCompilerError "Expected instDef"

instsToMap :: [ProcInst] -> M.HashMap Int ProcInst
instsToMap = foldr (\p@ProcInst {..} m -> M.insert instNodeId p m) M.empty

setupSimEnv :: SimM ()
setupSimEnv = do
  modify
    (\x ->
       x {ext = EnvExt { labelSource = 0
                       , curVtable = M.empty
                       , links = []}} :: SimEnv)
  labelInstances
  --constructGraph
  entry <- getNetworkEntry
  tree <- lookupTopDef entry >>= instEntity M.empty
  let insts = flattenInstTree tree
  liftIO $ putStrLn $ ppShow tree
  let instMap = instsToMap insts
  links <- getLinks
  nodes' <-
    concat <$>
    mapM
      (\(ProcLink (n1, n2, l, shouldBeUsed)) -> do
         ref1 <- liftIO $ newIORef $ instMap M.! n1
         ref2 <- liftIO $ newIORef $ instMap M.! n2
         return [(n1, ref1), (n2, ref2)])
      links
  let edges = map (\(ProcLink (n1, n2, l, _)) -> (n1, n2, l)) links
      graph = ProcGraph $ mkGraph nodes' edges
      buses = nub $ map (\(ProcLink (_, _, _, b)) -> b) links
  procs <- liftIO $ mapM newIORef insts -- nub $ map snd nodes'
  liftIO $ print (length buses, length procs)
  _ <- replicateM 10 $ runSimulation procs buses
  return ()

modifyIORefM :: (MonadIO m) => (a -> m a) -> IORef a -> m ()
modifyIORefM !f r = liftIO (readIORef r) >>= f >>= (liftIO . writeIORef r)

runSimulation :: [IORef ProcInst] -> [BusInst] -> SimM ()
runSimulation procs buses = do
  mapM_ propagateBus buses
  mapM_ (modifyIORefM runProcess) procs

toSimEnv :: Env -> SimEnv
toSimEnv = (<$) EmptyExt

runSimM :: Env -> SimM a -> IO (Either TypeCheckErrors a, SimEnv)
runSimM env act = runReprM (toSimEnv env) (unSimM act)

simulate :: Env -> IO () --(Either TypeCheckErrors SimEnv)
simulate e =
  void $ runSimM e setupSimEnv


-- We initialize a entity content by creating a value table initialized with
-- default values defined in the syntax. TODO: Per definition, default values
-- for expressions may be any static expression. Currently, the type checker
-- will only accept numeric literals as default value initializers. This should
  -- be fixed by having the type checker recursively look up expressions. For the
-- type checker, the expression types should be propagated back, while in the
-- simulator, static expressions should be evaluated. The type checker should
-- make sure that expressions that are passed on are actually static. This could
-- be done by building a dependency graph of the declarative part of each
-- process deciding the order that definitions should be instantiated in. Value
-- tables for network declarations are transient since network tables are not
-- present in the runtime representation. Value tables for processes, on the
-- other hand, are permanent as they exist for the duration of the process. The
-- entity instantiation functions are initially handed a value table where

-- addInst :: Ident -> ProcInst -> SimM ()
-- addInst i inst = do
--   traceM $ "Adding to inst: " ++ show i
--   updateCurEnv
--     (\d ->
--        let e = topExt d
--            e' = e {symTable = M.insert i (InstVal inst) (symTable e)}
--        in d {ext = e'})

-- getInst :: Ident -> SimM (Maybe ProcInst)
-- getInst i = do
--   e <- getCurEnv
--   return $ M.lookup i (instTab (topExt e))
--mkPhantomInstnace :: Ident -> SimM


-- instantiateNetwork :: Ident -> SimM ()
-- instantiateNetwork i = do
--   lookupTopDef i >>= \case
--     t@NetworkTable{netName = netName} ->
--       withScope netName $ instNetwork t
--     t@ProcessTable{} -> instProcess t


  -- (e, env) <-runSimM e setupSimEnv
  -- case e of


-- constructGraph :: SimM ()
-- constructGraph = do
--   edges' <- concat <$> mapUsedTopDefsM go
--   let nodes' = concatMap (\(e1, e2) -> [e1, e2]) edges'
--       edges'' = map (\((n1, s1), (n2, s2)) -> (n1, n2, s1 ++ "_" ++ s2)) edges'
--       graph = NetGraph $ mkGraph nodes' edges''
--   liftIO $ prettyPrint (unInstGraph graph)
  --     --go :: SimM (NodeMapM String String
--   where
--     go :: TopDef -> SimM [(LNode String, LNode String)]
--     go ProcessTable {..} = return []
--     go NetworkTable {netName = netName, symTable = symTable} =
--       concat <$> withScope netName (mapM go' (M.elems symTable))
--       where
--         go' InstDef { params = params
--                     , instName = thisInstName
--                     , ext = InstExt {nodeId = thisNodeId}
--                     } = do
--           siblings <-
--             forM
--               params
--               (\x -> do
--                  def <- lookupDef x
--                  traceM ("LookupDef in Simulate returned " ++ show def)
--                  return
--                    ( nodeId ((ext :: DefType -> SimExt) def)
--                    , toString ((instName :: DefType -> Ident) def)))
--           return $ map (\y -> ((thisNodeId, toString thisInstName), y)) siblings
--         go' _ = return []

-- --makeProcInst :: SimM ()

--data Instance

-- notes:

-- TODO (maybe): Parameterize the Name type of the SAT such that names can be
-- changed to a type which holds values.
-- Algorithm:
-- 1) Build execution environments for every process holding the value of local
-- variables
-- 2) Connect all buses to value references
-- 3) Connect all processes to a clock signal
-- 4) Run all process instances in parallel together with a process for running
-- the clock
-- 5) Log a trace of the values of every bus.
-- 6) How can we communicate with external processes in this manner?

-- Have a broadcasting channel for clock. All processes awaits a clock signal on
-- this channels. For communicating completed computation back to the execution
-- manager use a TMVar and set it to the ID of the finished process. When all
-- processes have reported in, swap the buses and tick the clock.

-- Prototype: Simulate simple self-generating networks

-- An instance should contain a reference to a bus instance linked to that
-- instance. When another process links to that bus, we should look up and link
-- to its instance and not the actual definition

-- Evaluate every top-level network definition. Create instances of processes
-- for every instance declaration. Keep track of instances in a map such that we
-- can resolve an instance name through a top-level reference. This is used for
-- resolving references to default instances of top-level processes. It may not
-- be so simple: for every instantiated process, either look up the instance and
-- create a reference to existing buses or create a new bus definition.

-- TODO: Using buses declared in processes with multiple instances by referring
-- to the bus through the process name is ambiguous (unless the bus is
-- unique). Keep track of this in the type checker by logging which tracking
-- when a bus is instantiated. A simple rule here could be that if a bus is
-- instnatiated with a name, it's buses must be referenced through the instance
-- name (i.e. passed as a parameter) when used as input for another
-- bus. Alternatively, (or complimentary) we build a graph of instnaces which
-- will make it easy to spot irresolvable ambiguous connections.

-- Connection map building algorithm:
-- 1) When an instance declaration is encountered, create an instance for that
-- process and also instantiate all buses that it uses
-- 2) Assumption here: When we instantiate a bus, we know the context that it is
-- instantiated in so the process types of other instance are easily accessible.
-- 3) ..
--
-- 1) When encountering a process
---- 2)
