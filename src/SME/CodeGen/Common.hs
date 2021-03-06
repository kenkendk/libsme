{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module SME.CodeGen.Common
  ( Env
  , TopDef
  , DefType
  , OutputPlan
  , OutputFile (..)
  , GenM
  , TypeContext(..)
  , withType
  , withType'
  , getType
  , runGenM
  , execGenM
  , fileName
  ) where

import           Control.Monad.Reader  (MonadReader, ReaderT, ask, local,
                                        runReaderT)
import           Control.Monad.State   (MonadState)
import qualified Data.Text             as T
import           System.FilePath       ((<.>))

import           Language.SMEIL.Syntax (Typed (..), Typeness (..))
import           SME.Error
import           SME.Representation

type Env = BaseEnv Void
type TopDef = BaseTopDef Void
type DefType = BaseDefType Void

type OutputPlan = [OutputFile]

data OutputFile = OutputFile
  { destFile :: FilePath
  , fileExt  :: String
  , content  :: T.Text
  , deps     :: [String]
  }
  deriving (Show)

fileName :: OutputFile -> FilePath
fileName OutputFile {destFile = d, fileExt = e} = d <.> e

newtype TypeContext = TypeContext { unTyCtx :: Typeness }

withType :: (Typed a) => (a -> GenM b) -> a -> GenM b
withType act e = local (const $ TypeContext (typeOf e)) (act e)

withType' :: Typeness -> GenM a -> GenM a
withType' ty = local (const $ TypeContext ty)

getType :: GenM Typeness
getType = unTyCtx <$> ask

newtype GenM a = GenM
  { unGenM :: ReaderT TypeContext (ReprM (Either SomeException) Void) a
  } deriving ( Functor
             , Applicative
             , Monad
             , MonadState Env
             , MonadReader TypeContext
             , MonadThrow
             )

instance (MonadRepr Void) GenM

runGenM :: Env -> GenM a -> Either SomeException (a, Env)
runGenM env act =
  runReprM env $ runReaderT (unGenM act) (TypeContext Untyped)

execGenM :: Env -> GenM a -> Either SomeException Env
execGenM env act =
  runGenM env act >>= pure . snd
