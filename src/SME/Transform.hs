{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections              #-}

module SME.Transform
  ( transform
  ) where

import           Control.Monad.State         (MonadState, when)
import qualified Data.Generics.Uniplate.Data as U
import qualified Data.HashMap.Strict         as M
import qualified Data.List.NonEmpty          as N
import qualified Data.Set                    as S
import qualified Data.Text                   as T
import           Data.Tuple.Extra            (second, snd3, thd3)

import           Language.SMEIL.Syntax
import           SME.Error
import           SME.Representation
import           SME.Util

type Env = BaseEnv Void
type TopDef = BaseTopDef Void

newtype TrM a = TrM
  { unTrM :: ReprM (Either SomeException) Void a
  } deriving (Functor, Applicative, Monad, MonadState Env, MonadThrow)

instance (MonadRepr Void) TrM

type BusList = [Ref]
type BusStateList = [(Ref, BusState)]

transTopDef :: TopDef -> TrM ()
transTopDef d = do
  let buses = directBuses (usedBuses d)
  transDefs d buses
  let tdn = nameOf d
  td <- lookupTopDef tdn
  td' <-
    U.transformBiM
      (\x ->
         if busListElem buses x
           then renameBodyName x
           else pure x)
      td
  withScope tdn $ do
    (act, td'') <- updateTopDefParams td'
    updateTopDef (refOf (nameOf d)) (const td'')
    act


updateTopDefParams :: TopDef -> TrM (TrM (), TopDef)
updateTopDefParams pt@ProcessTable {procDef = pd, params = pars} = do
  let buses = directStateBuses (usedBuses pt)
  entDefParamas <- genTopDeclParams buses
  topDefParams <- genParamTypeParam buses
  let pt' = appendParams pd entDefParamas
  let act = addParamDefs topDefParams
  return (act, pt {procDef = pt', params = pars ++ topDefParams})
  where
    appendParams p@Process {..} ps = p {params = params ++ ps} :: Process
updateTopDefParams nt@NetworkTable {netDef = nd, params = pars} = do
  let buses = directStateBuses (usedBuses nt)
  entDefParamas <- genTopDeclParams buses
  topDefParams <- genParamTypeParam buses
  let nd' = appendParams nd entDefParamas
  let act = addParamDefs topDefParams
  return (act, nt {netDef = nd', params = pars ++ topDefParams})
  where
    appendParams n@Network {..} ps = n {params = params ++ ps} :: Network

addParamDefs :: [(Ident, ParamType)] -> TrM ()
addParamDefs = mapM_ go
  where
    go (i, pt) = addDefinition i (ParamDef i pt Void)

genParamTypeParam :: BusStateList -> TrM [(Ident, ParamType)]
genParamTypeParam = mapM go
  where
    go (r, bs) = do
      pn <- mkParName r
      (pn, ) <$>
        (BusPar r (refOf pn) <$> (busShape <$> lookupBus r) <*> pure bs <*>
         pure Nothing)

genTopDeclParams :: BusStateList -> TrM [Param]
genTopDeclParams = mapM toParamList
  where
    toParamList (r, bs) =
      Param Nothing <$> mapBusState bs <*> mkParName r <*> pure noLoc
      where
        mapBusState Input  = pure (In noLoc)
        mapBusState Output = pure (Out noLoc)
        mapBusState _      = bad "Invalid BusState for direct bus"

busListElem :: (References a) => BusList -> a -> Bool
busListElem bl r = any (cmpNRef 2 r) bl

-- | Compares the first n components of two references
cmpNRef :: (References a, References b) => Int -> a -> b -> Bool
cmpNRef n r1 r2 = N.take n (refOf r1) == N.take n (refOf r2)

-- | Appends external buses to instance declarations of a top-level entity
transDefs :: TopDef -> BusList -> TrM ()
transDefs td _ =
  updateDefsM_ (nameOf td) $ \case
    i@InstDef {..} -> do
      bl <- map toAnonName <$> getDirectBuses instantiated
      let params' = mkInstPars bl
      i' <- transInstDef instDef params'
      let res = i {instDef = i', params = params ++ params'}
      return res
    d -> pure d
  where
    mkInstPars :: BusList -> [InstParam]
    mkInstPars = map InstBusPar

transInstDef :: Instance -> [InstParam] -> TrM Instance
transInstDef i@Instance {..} ps = do
  pars <- toParamList ps
  return (i { params = params ++ pars} :: Instance)
  where
    toParamList = mapM go
      where
        go (InstConstPar _) = bad "Const par generated by process transformation"
        go (InstBusPar r) = pure (Nothing, refToExpr r)

toIdent :: T.Text -> Ident
toIdent t = Ident t noLoc

-- | Concatenates the two first components of a references separated by an
-- underscore
mkParName :: Ref -> TrM Ident
mkParName (fstR :| (sndR:_)) =
  let res = fstR <> toIdent "_" <> sndR
  in pure res
mkParName _                  = bad "Bad number of reference compounds"

renameBodyName :: Name -> TrM Name
renameBodyName n@Name {parts = IdentName {} :| (IdentName {}:restNP)} = do
  n' <- mkParName (refOf n)
  let parts' = IdentName n' (fromLoc $ locOf n') :| restNP
  return (Name parts' (concatLocs parts'))
renameBodyName n = pure n

toAnonName :: Ref -> Ref
toAnonName (Ident n loc :| r) = Ident ("__anonymous_" <> n) loc :| r

refToExpr :: Ref -> Expr
refToExpr ref = PrimName Untyped (refToName ref) (concatLocs ref)

refToName :: Ref -> Name
refToName r'' =
  let parts = N.map (\i@Ident {loc = loc} -> IdentName i loc) r''
  in Name parts (concatLocs parts)

concatLocs :: (Located a) => NonEmpty a -> SrcLoc
concatLocs = fromLoc . nsconcatMap locOf

getDirectBuses :: Ident -> TrM BusList
getDirectBuses r = (directBuses . usedBuses) <$> lookupTopDef r

distribSnd :: (a, [b]) -> [(a, b)]
distribSnd (a, bs) = map (\b -> (a, b)) bs

directBuses :: UsedBuses -> BusList
directBuses = map fst . directStateBuses

directStateBuses :: UsedBuses -> BusStateList
directStateBuses ub =
  let allDirect = M.map (S.map snd3 . S.filter thd3) ub
  in concatMap (distribSnd . second S.toList) $
     filter (not . S.null . snd) (M.toList allDirect)

hasDirectBuses :: UsedBuses -> Bool
hasDirectBuses = not . null . directBuses

doTrans :: TrM ()
doTrans = do
  -- Only invoke transformation mechanics for programs which actually contains
  -- direct buses
  hasDBus <- or <$> mapUsedTopDefsM (return . hasDirectBuses . usedBuses)
  when hasDBus $ mapUsedTopDefsM_ $ \td -> transTopDef td

runTrM :: Env -> TrM a -> Either SomeException (a, Env)
runTrM e = runReprM e  . unTrM

transform :: Env -> IO Env
transform e =
  case runTrM e doTrans of
    (Left err)     -> throw err
    (Right (_, s)) -> return s
