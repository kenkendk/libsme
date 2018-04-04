{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- For the R.Value instance. We want to run as little as possible through the
-- c2hs preprocessor
{-# OPTIONS_GHC -fno-warn-orphans #-}

module SME.CTypes (SMECType(..), ChannelVals, readPtr, writePtr) where

import Foreign.C.Types (CChar, CFloat(..), CDouble(..))
import Foreign.Ptr (castPtr)
import Foreign.Storable (Storable(..))
import GHC.Exts (Word(..), Ptr(..));

import GHC.Integer.GMP.Internals (importIntegerFromAddr,
                                  exportIntegerToAddr,
                                  sizeInBaseInteger)

import qualified SME.Representation as R

#include "libsme.h"

{# enum Type as SMECType {underscoreToCase} deriving (Eq, Show) #}

data SMEInteger = SMEInteger
  { negative :: Bool
  , len :: Word
  , addr :: Ptr CChar
  , valPtr :: Ptr SMEInteger
  }

data SMEInt
type SMEIntPtr = Ptr SMEInt

data Signedness = Signed | Unsigned
  deriving (Eq)

data ChannelVals = ChannelVals
  { readPtr :: Ptr R.Value
  , writePtr :: Ptr R.Value
  }

foreign import ccall "sme_integer_resize"
    sme_integer_resize :: Ptr SMEInteger -> Word -> IO()

instance Storable ChannelVals where
  sizeOf _ = {# sizeof ChannelVals #}
  alignment _ = {# alignof ChannelVals #}

  poke p value = do
    let rp = (castPtr :: Ptr R.Value -> Ptr ()) (readPtr value)
        wp = (castPtr :: Ptr R.Value -> Ptr ()) (writePtr value)
    {# set ChannelVals.read_ptr #} p rp
    {# set ChannelVals.write_ptr #} p wp
  {-# INLINE poke #-}

  peek p = do
    rp <- {# get ChannelVals.read_ptr #} p
    wp <- {# get ChannelVals.write_ptr #} p
    let cast = (castPtr :: Ptr () -> Ptr R.Value)
    return $ ChannelVals (cast rp) (cast wp)
  {-# INLINE peek #-}

instance Storable SMEInteger where
  sizeOf _ = {# sizeof SMEInt #}
  alignment _ = {# alignof SMEInt #}

  poke p value = do
    -- All other fields are non modifiable from here
    {# set SMEInt.negative #} p (negative value)
  {-# INLINE poke #-}

  peek p =
    SMEInteger <$> {# get SMEInt.negative #} p
               <*> (fromIntegral <$> {# get SMEInt.len #} p)
               <*> {# get SMEInt.num #} p
               <*> pure p
  {-# INLINE peek #-}


pokeIntVal :: Signedness -> (t -> IO (Ptr ())) -> t -> Integer -> IO ()
pokeIntVal signedness f p val = do
  let bytes = if val == 0 then 1 else W# (sizeInBaseInteger val 256#)
  --putStrLn ("Got numstring size " ++ show bytes)
  iptr' <- f p
  let iptr = (castPtr :: Ptr () -> Ptr SMEInteger) iptr'
  sme_integer_resize iptr bytes
  intRep <- peek iptr
  let !(Ptr unpackedAddr) = addr intRep
  --putStrLn ("Writing int to val " ++ show (val))
  _ <- exportIntegerToAddr val unpackedAddr 0#
  --putStrLn ("Wrote bytes " ++ show res)
  poke iptr (intRep { negative = ((signedness == Signed) && (val < 0)) })
{-# INLINE pokeIntVal #-}

peekIntVal :: Signedness -> (t -> IO (Ptr())) -> t -> IO Integer
peekIntVal signedness f p = do
  iptr <- f p
  intRep <- peek ((castPtr :: Ptr () -> Ptr SMEInteger) iptr)
  let !(W# unpackedLen) = len intRep
  let !(Ptr unpackedAddr) = addr intRep
  res <- importIntegerFromAddr unpackedAddr unpackedLen 0#
  --putStrLn ("Negative is " ++ show (negative intRep))
  return $ case signedness of
    Signed -> if negative intRep then negate res else res
    Unsigned -> res
{-# INLINE peekIntVal #-}

instance Storable R.Value where
  sizeOf _ = {# sizeof Value #}
  alignment _ = {# alignof Value #}

  poke p value =
    -- let
    -- setValType x = {# set Value.type #} p $ fromIntegral (fromEnum $ x)
    -- in
      case value of
        R.IntVal i ->
          pokeIntVal Signed {# get Value.value.integer #} p i
        -- SMEUInt i ->
        --   pokeIntVal Unsigned {# get Value.value.integer #} p i
        -- SMENativeInt i -> do
        --   setValType SmeNativeInt
        --   {# set Value.value.native_int #} p $ fromIntegral i
        -- SMENativeUint i -> do
        --   setValType SmeNativeUint
        --   {# set Value.value.native_uint #} p $ fromIntegral i
        R.SingleVal i -> do
          {# set Value.value.f32 #} p $ CFloat i
        R.DoubleVal i -> do
--          setValType SmeDouble
          {# set Value.value.f64 #} p $ CDouble i
        R.BoolVal i -> do
--          setValType SmeBool
          {# set Value.value.boolean #} p $ i
  {-# INLINE poke #-}

  peek p =
      ((toEnum . fromIntegral) <$> ({# get Value.type #} p)) >>= \case
        SmeInt ->
          R.IntVal <$> peekIntVal Signed {# get Value.value.integer #} p
        SmeUint ->
          R.IntVal <$> peekIntVal Unsigned {# get Value.value.integer #} p
        -- SmeNativeInt ->
        --   SMENativeInt . fromIntegral  <$> ({# get Value.value.native_int #} p)
        -- SmeNativeUint ->
        --   SMENativeUint . fromIntegral  <$> ({# get Value.value.native_uint #} p)
        SmeFloat -> do
          (CFloat f) <- ({# get Value.value.f32 #} p)
          return $ R.SingleVal f
        SmeDouble -> do
          (CDouble f) <- ({# get Value.value.f64 #} p)
          return $ R.DoubleVal f
        SmeBool ->
          R.BoolVal <$> ({# get Value.value.boolean #} p)
  {-# INLINE peek #-}