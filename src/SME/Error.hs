{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module SME.Error
  ( ImportingError(..)
  , FrontendErrors(..)
  , CompilerError (..)
  , TypeCheckErrors(..)
  , RenderError(..)
  ) where

import           Control.Exception
import           Data.Containers       (IsMap (..))
import           Data.Loc
import qualified Data.Map.Strict       as M
import           Data.Maybe            (fromMaybe)

import           Language.SMEIL.Pretty
import           Language.SMEIL.Syntax (Nameable (..), Ref, ToString (..),
                                        Typeness (..))
newtype CompilerError =
  CompilerError String
  deriving (Exception)

instance Show CompilerError where
  show (CompilerError e) = show e

data FrontendErrors
  = DirAlreadyExists FilePath
  | FileNotFound FilePath
  deriving (Exception)

instance Show FrontendErrors where
  show (DirAlreadyExists fp) =
    "Directory " ++ fp ++ " already exists. Use --force to use it anyway"
  show (FileNotFound fp) = "File not found: " ++ fp

data TypeCheckErrors where
  DuplicateName
    :: (ToString a, Located a, ToString b, Located b)
    => a
    -> b
    -> TypeCheckErrors
  UndefinedName :: (Pretty a, Located a) => a -> TypeCheckErrors
  TypeMismatchError :: Typeness -> Typeness -> TypeCheckErrors
  ParamCountMismatch
    :: (Located a, Nameable a, Located b, Nameable b)
    => Int
    -> Int
    -> a
    -> b
    -> TypeCheckErrors
  ExpectedBus :: (ToString a, Located a) => a -> TypeCheckErrors
  ExprInvalidInContext :: (Pretty a, Located a) => a -> TypeCheckErrors
  NamedParameterMismatch
    :: (ToString a, Located a, Nameable b) => a -> a -> b -> TypeCheckErrors
  BusShapeMismatch :: (Show a, Located b) => a -> a -> b -> TypeCheckErrors
  InstanceParamTypeMismatch :: (Located a) => a -> TypeCheckErrors
  ReferencedAsValue :: (Located a, Nameable a) => a -> TypeCheckErrors
  BusReferencedAsValue :: (Located a, Pretty a) => a -> TypeCheckErrors
  WroteConstant :: (Located a, Pretty a) => a -> TypeCheckErrors
  WroteInputBus :: (Located a, Pretty a) => a -> TypeCheckErrors
  ReadOutputBus :: (Located a, Pretty a) => a -> TypeCheckErrors
  NotAnArray :: (Located a, Pretty a) => a -> TypeCheckErrors
  InternalCompilerError :: String -> TypeCheckErrors
  deriving (Exception)

class (IsMap map, Show ex) => RenderError map ex where
  renderError :: map -> ex -> String

--instance (IsMap m) => RenderError m TypeCheckErrors where
instance RenderError (M.Map String Ref) TypeCheckErrors where
  renderError m (ParamCountMismatch expected actual inst' ent) =
    "Wrong number of parameters. Entity " ++
    origName ent m ++
    " (at " ++
    displayLoc (locOf ent) ++
    ")" ++
    " expected " ++
    pluralize expected "parameter" ++
    " but was instantiated with " ++
    pluralize actual "parameter" ++ " at " ++ displayLoc (locOf inst') ++ "."
  renderError m (NamedParameterMismatch expected actual ent) =
    "The name of parameter " ++
    toString actual ++
    " in instance declaration of " ++
    origName ent m ++
    " at " ++
    displayLoc (locOf actual) ++
    " is actually named " ++ toString expected ++ "."
  renderError _ e = show e

origName :: (Nameable a) => a -> M.Map String Ref -> String
origName k m = case M.lookup (toString (nameOf k)) m of
  Just r  -> pprrString r
  Nothing -> toString (nameOf k)

instance Show TypeCheckErrors where
  show e@NamedParameterMismatch {} = renderError (M.empty :: M.Map String Ref) e
  show e@ParamCountMismatch {} = renderError (M.empty :: M.Map String Ref) e
  show (DuplicateName new prev) =
    "Name " ++
    toString new ++
    " already defined at " ++
    displayLoc (locOf new) ++
    ". Previous definition was " ++ displayLoc (locOf prev)
  show (UndefinedName n) =
    "Name " ++
    pprrString n ++ " is undefined at " ++ displayLoc (locOf n) ++ "."
  show (TypeMismatchError t1 t2) =
    "Cannot match type " ++
    pprrString t2 ++
    " with expected type " ++ pprrString t1 ++ ". At " ++ displayLoc (locOf t2)
  show (ExpectedBus i) =
    "Parameter " ++
    toString i ++
    " does not refer to a bus as expected at " ++ displayLoc (locOf i)
  show (ExprInvalidInContext e) =
    "Expression: " ++
    pprrString e ++ " is invalid in context at " ++ displayLoc (locOf e)
  show (BusShapeMismatch expected actual inst) =
    "Unable to unify bus shapes in instantiation at " ++
    displayLoc (locOf inst) ++
    " expected: " ++ show expected ++ " but saw " ++ show actual ++ "."
  show (InstanceParamTypeMismatch inst) =
    "Wrong parameter type (bus parameter where a constant is expected or vice-versa) in instantiation at " ++
    displayLoc (locOf inst)
  show (ReferencedAsValue def) =
    "Object " ++
    toString (nameOf def) ++
    " referenced as value " ++ displayLoc (locOf def) ++ "."
  show (BusReferencedAsValue def) =
    "Bus " ++
    pprrString def ++
    " referenced as value at " ++
    displayLoc (locOf def) ++ ". Maybe you meant to access one of its channels?"
  show (WroteInputBus def) =
    "Cannot write to input bus " ++
    pprrString def ++ " at " ++ displayLoc (locOf def)
  show (WroteConstant def) =
    "Cannot write to read-only constant " ++
    pprrString def ++ " at " ++ displayLoc (locOf def)
  show (ReadOutputBus def) =
    "Cannot read from output bus " ++
    pprrString def ++ " at " ++ displayLoc (locOf def)
  show (NotAnArray def) =
    pprrString def ++ " is not an array at " ++ displayLoc (locOf def)
  show (InternalCompilerError msg) =
    "Internal compiler error (probable compiler bug): " ++ msg

data ImportingError where
  ImportNotFoundError :: FilePath -> SrcLoc -> ImportingError
  UndefinedIdentifierError
    :: (ToString a, Located a) => [a] -> SrcLoc -> ImportingError
  IdentifierClashError
    :: (ToString a, Located a) => [a] -> SrcLoc -> ImportingError
  ParseError :: String -> ImportingError
  deriving (Exception)

instance Show ImportingError where
  show (ImportNotFoundError f l) =
    "Imported file not found " ++ f ++ "." ++ importedFromMsg l
  show (UndefinedIdentifierError ids l) =
    "Unknown identifier(s) " ++ prettyList ids ++ "." ++ importedFromMsg l
  show (IdentifierClashError ids l) =
    "Specific imports " ++
    prettyList ids ++
    " clashes with names already defined in module." ++ importedFromMsg l
  show (ParseError s) = "Parse error at " ++ s

importedFromMsg :: SrcLoc -> String
importedFromMsg (SrcLoc NoLoc) = ""
importedFromMsg (SrcLoc l)     = " Imported from " ++ displayLoc l

displayLoc' :: (Located a) => a -> String
displayLoc' = displayLoc . locOf

prettyList :: (ToString s, Located s) => [s] -> String
prettyList []     = ""
prettyList [x]    = toString x ++ "(defined at " ++ displayLoc' x ++ ")"
prettyList [x, y] = prettyList [x] ++ " and " ++ prettyList [y]
prettyList (x:xs) = prettyList [x] ++ ", " ++ prettyList xs

pluralize :: (Num a, Eq a, Show a) => a -> String -> String
pluralize i s = pluralize' i s Nothing

pluralize' :: (Num a, Eq a, Show a) => a -> String -> Maybe String -> String
pluralize' i s s'
  | i == 1 = show i ++ " " ++ s
  | otherwise = show i ++ " " ++ fromMaybe (s ++ "s") s'
