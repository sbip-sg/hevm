{-# Language OverloadedStrings #-}
{-# Language BangPatterns #-}
{-# Language LambdaCase #-}
{-# Language FlexibleContexts #-}
{-# Language TemplateHaskell #-}
{-# Language DeriveGeneric, DeriveAnyClass #-}

module EVM.ABI where

import EVM.Keccak

import Control.Monad
import Data.Word (Word32, Word8)
import Data.Binary.Put
import Data.Binary.Get
import Data.Bits
import Data.DoubleWord
import Data.Monoid
import Data.Text (Text, pack)
import Data.Text.Encoding (encodeUtf8)
import Data.Vector (Vector)
import Text.Printf (printf)

import Data.ByteString (ByteString)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSLazy
import qualified Data.Vector as Vector
import qualified Data.Text as Text

import Test.QuickCheck hiding ((.&.), label)
import Test.QuickCheck.Utf8

data AbiValue
  = AbiUInt         !Int !Word256
  | AbiInt          !Int !Int256
  | AbiAddress      !Word160
  | AbiBool         !Bool
  | AbiBytes        !Int !BS.ByteString
  | AbiBytesDynamic !BS.ByteString
  | AbiString       !BS.ByteString
  | AbiArrayDynamic !AbiType !(Vector AbiValue)
  | AbiArray        !Int !AbiType !(Vector AbiValue)
  deriving (Show, Read, Eq, Ord)

data AbiType
  = AbiUIntType         !Int
  | AbiIntType          !Int
  | AbiAddressType
  | AbiBoolType
  | AbiBytesType        !Int
  | AbiBytesDynamicType
  | AbiStringType
  | AbiArrayDynamicType !AbiType
  | AbiArrayType        !Int !AbiType
  deriving (Show, Read, Eq, Ord)

genAbiValue :: AbiType -> Gen AbiValue
genAbiValue = \case
   AbiUIntType n -> genUInt n
   AbiIntType n ->
     do AbiUInt _ x <- genUInt n
        b <- arbitrary
        pure $ AbiInt n (signedWord x * if b then 1 else -1)
   AbiAddressType ->
     (\(AbiUInt _ x) -> AbiAddress (fromIntegral x)) <$> genUInt 20
   AbiBoolType ->
     elements [AbiBool False, AbiBool True]
   AbiBytesType n ->
     do xs <- replicateM n arbitrary
        pure (AbiBytes n (BS.pack xs))
   AbiBytesDynamicType ->
     AbiBytesDynamic . BS.pack <$> listOf arbitrary
   AbiStringType ->
     AbiString . BS.pack <$> listOf arbitrary
   AbiArrayDynamicType t ->
     do xs <- listOf1 (scale (`div` 2) (genAbiValue t))
        pure (AbiArrayDynamic t (Vector.fromList xs))
   AbiArrayType n t ->
     AbiArray n t . Vector.fromList <$>
       replicateM n (scale (`div` 2) (genAbiValue t))
  where
    genUInt n =
       do x <- pack8 (div n 8) <$> replicateM n arbitrary
          pure . AbiUInt n $
            if n == 256 then x else mod x (2 ^ n)

instance Arbitrary AbiType where
  arbitrary = oneof
    [ (AbiUIntType . (* 8)) <$> choose (1, 32)
    , (AbiIntType . (* 8)) <$> choose (1, 32)
    , pure AbiAddressType
    , pure AbiBoolType
    , AbiBytesType . getPositive <$> arbitrary
    , pure AbiBytesDynamicType
    , pure AbiStringType
    , AbiArrayDynamicType <$> scale (`div` 2) arbitrary
    , AbiArrayType <$> (getPositive <$> arbitrary) <*> scale (`div` 2) arbitrary
    ]

instance Arbitrary AbiValue where
  arbitrary = arbitrary >>= genAbiValue
  shrink = \case
    AbiArrayDynamic t v ->
      Vector.toList v ++
        map (AbiArrayDynamic t . Vector.fromList)
            (shrinkList shrink (Vector.toList v))
    AbiArray n t v ->
      Vector.toList v ++
        map (\x -> AbiArray (length x) t (Vector.fromList x))
            (shrinkList shrink (Vector.toList v))
    x -> []

data AbiKind = Dynamic | Static

abiKind :: AbiType -> AbiKind
abiKind = \case
  AbiBytesDynamicType   -> Dynamic
  AbiStringType         -> Dynamic
  AbiArrayDynamicType _ -> Dynamic
  AbiArrayType _ t      -> abiKind t
  _                     -> Static

abiValueType :: AbiValue -> AbiType
abiValueType = \case
  AbiUInt n _         -> AbiUIntType n
  AbiInt n _          -> AbiIntType  n
  AbiAddress _        -> AbiAddressType
  AbiBool _           -> AbiBoolType
  AbiBytes n _        -> AbiBytesType n
  AbiBytesDynamic _   -> AbiBytesDynamicType
  AbiString _         -> AbiStringType
  AbiArrayDynamic t _ -> AbiArrayDynamicType t
  AbiArray n t _      -> AbiArrayType n t

abiTypeSolidity :: AbiType -> Text
abiTypeSolidity = \case
  AbiUIntType n  -> "uint" <> pack (show n)
  AbiIntType n   -> "int" <> pack (show n)
  AbiAddressType -> "address"
  AbiBoolType    -> "bool"
  AbiBytesType n -> "bytes" <> pack (show n)
  AbiBytesDynamicType -> "bytes"
  AbiStringType -> "string"
  AbiArrayDynamicType t -> abiTypeSolidity t <> "[]"
  AbiArrayType n t -> abiTypeSolidity t <> "[" <> pack (show n) <> "]"

pack32 :: Int -> [Word32] -> Word256
pack32 n xs =
  sum [ shiftL x ((n - i) * 32)
      | (x, i) <- zip (map fromIntegral xs) [1..] ]

pack8 :: Int -> [Word8] -> Word256
pack8 n xs =
  sum [ shiftL x ((n - i) * 8)
      | (x, i) <- zip (map fromIntegral xs) [1..] ]

asUInt :: Integral i => Int -> (i -> a) -> Get a
asUInt n f = (\(AbiUInt _ x) -> f (fromIntegral x)) <$> getAbi (AbiUIntType n)

getWord256 :: Get Word256
getWord256 = pack32 8 <$> replicateM 8 getWord32be

roundTo256Bits :: Integral a => a -> a
roundTo256Bits n = 32 * div (n + 255) 256

getBytesWith256BitPadding :: Integral a => a -> Get ByteString
getBytesWith256BitPadding i =
  (BS.pack <$> replicateM n getWord8)
    <* skip ((roundTo256Bits n) - n)
  where n = fromIntegral i

getAbi :: AbiType -> Get AbiValue
getAbi t = label (Text.unpack (abiTypeSolidity t)) $
  case t of
    AbiIntType n   -> asUInt n (AbiInt n)
    AbiAddressType -> asUInt 256 AbiAddress
    AbiBoolType    -> asUInt 256 (AbiBool . (== (1 :: Int)))
    AbiBytesType n -> AbiBytes n <$> getBytesWith256BitPadding n

    AbiUIntType n  -> do
      let word32Count = 8 * div (n + 255) 256
      xs <- replicateM word32Count getWord32be
      pure (AbiUInt n (pack32 word32Count xs))

    AbiBytesDynamicType ->
      AbiBytesDynamic <$>
        (label "bytes length prefix" getWord256
          >>= label "bytes data" . getBytesWith256BitPadding)

    AbiStringType -> do
      AbiBytesDynamic x <- getAbi AbiBytesDynamicType
      pure (AbiString x)

    AbiArrayDynamicType t' -> do
      AbiUInt _ n <- label "array length" (getAbi (AbiUIntType 256))
      AbiArrayDynamic t' <$>
        label "array body" (getAbiSeq (fromIntegral n) (repeat t'))

    AbiArrayType n t' ->
      AbiArray n t' <$> getAbiSeq n (repeat t')

getAbiSeq :: Int -> [AbiType] -> Get (Vector AbiValue)
getAbiSeq n ts = label "sequence" $ do
  hs <- label "sequence head" (getAbiHead n ts)
  Vector.fromList <$>
    label "sequence tail" (mapM (either getAbi pure) hs)

getAbiHead :: Int -> [AbiType]
  -> Get [Either AbiType AbiValue]
getAbiHead 0 _      = pure []
getAbiHead _ []     = fail "ran out of types"
getAbiHead n (t:ts) = do
  case abiKind t of
    Dynamic ->
      (Left t :) <$> (skip 32 *> getAbiHead (n - 1) ts)
    Static ->
      do x  <- getAbi t
         xs <- getAbiHead (n - 1) ts
         pure (Right x : xs)

putAbi :: AbiValue -> Put
putAbi = \case
  AbiUInt n x -> do
    let word32Count = 8 * (div (n + 255) 256)
    forM_ (reverse [0 .. word32Count - 1]) $
      \i -> putWord32be (fromIntegral (shiftR x (i * 32) .&. 0xffffffff) )
  AbiInt n x -> putAbi (AbiUInt n (fromIntegral x))
  AbiAddress x -> putAbi (AbiUInt 160 (fromIntegral x))
  AbiBool x -> putAbi (AbiUInt 8 (if x then 1 else 0))
  AbiBytes n xs -> do
    let
      word32Count = 8 * (div (n + 255) 256)
      word8Count = word32Count * 4
    forM_ [0 .. n - 1] $
      \i -> putWord8 (BS.index xs i)
    replicateM_ (word8Count - n) (putWord8 0)
  AbiBytesDynamic xs -> do
    let
      n = BS.length xs
      word32Count = 8 * (div (n + 255) 256)
      word8Count = word32Count * 4
    putAbi (AbiUInt 256 (fromIntegral n))
    forM_ [0 .. n - 1] $
      \i -> putWord8 (BS.index xs i)
    replicateM_ (word8Count - n) (putWord8 0)
  AbiString s -> putAbi (AbiBytesDynamic s)
  AbiArrayDynamic _ xs -> do
    putAbi (AbiUInt 256 (fromIntegral (Vector.length xs)))
    abiSeq xs
  AbiArray _ _ xs ->
    abiSeq xs

abiTail :: AbiValue -> Put
abiTail x =
  case abiKind (abiValueType x) of
    Static  -> pure ()
    Dynamic -> putAbi x

abiValueSize :: AbiValue -> Int
abiValueSize x =
  case x of
    AbiUInt n _  -> roundTo256Bits n
    AbiInt  n _  -> roundTo256Bits n
    AbiBytes n _ -> roundTo256Bits n
    AbiAddress _ -> 32
    AbiBool _    -> 32
    AbiArray _ _ xs -> Vector.sum (Vector.map abiHeadSize xs) +
                       Vector.sum (Vector.map abiTailSize xs)
    AbiBytesDynamic xs -> 32 + roundTo256Bits (BS.length xs)
    AbiArrayDynamic _ xs -> 32 + Vector.sum (Vector.map abiHeadSize xs) +
                                Vector.sum (Vector.map abiTailSize xs)
    AbiString s -> 32 + roundTo256Bits (BS.length s)

abiTailSize :: AbiValue -> Int
abiTailSize x =
  case abiKind (abiValueType x) of
    Static -> 0
    Dynamic ->
      case x of
        AbiString s -> 32 + roundTo256Bits (BS.length s)
        AbiBytesDynamic s -> 32 + roundTo256Bits (BS.length s)
        AbiArrayDynamic _ xs -> 32 + Vector.sum (Vector.map abiValueSize xs)
        AbiArray _ _ xs -> Vector.sum (Vector.map abiValueSize xs)
        _ -> error "impossible"


abiHeadSize :: AbiValue -> Int
abiHeadSize x =
  case abiKind (abiValueType x) of
    Dynamic -> 32
    Static ->
      case x of
        AbiUInt n _  -> roundTo256Bits n
        AbiInt  n _  -> roundTo256Bits n
        AbiBytes n _ -> roundTo256Bits n
        AbiAddress _ -> 32
        AbiBool _    -> 32
        AbiArray _ _ xs -> Vector.sum (Vector.map abiHeadSize xs) +
                           Vector.sum (Vector.map abiTailSize xs)
        AbiBytesDynamic _ -> 32
        AbiArrayDynamic _ _ -> 32
        AbiString _       -> 32

abiSeq :: Vector AbiValue -> Put
abiSeq xs =
  do snd $ Vector.foldl' f (headSize, pure ()) (Vector.zip xs tailSizes)
     Vector.sequence_ (Vector.map abiTail xs)
  where
    headSize = Vector.sum $ Vector.map abiHeadSize xs
    tailSizes = Vector.map abiTailSize xs
    f (i, m) (x, j) =
      case abiKind (abiValueType x) of
        Static -> (i, m >> putAbi x)
        Dynamic -> (i + j, m >> putAbi (AbiUInt 256 (fromIntegral i)))

encodeAbiValue :: AbiValue -> BS.ByteString
encodeAbiValue = BSLazy.toStrict . runPut . putAbi

abiCalldata :: Text -> Vector AbiValue -> BS.ByteString
abiCalldata s xs = BSLazy.toStrict . runPut $ do
  putWord32be (abiKeccak (encodeUtf8 s))
  abiSeq xs

hexify :: BS.ByteString -> Text
hexify s = Text.pack (concatMap (printf "%02x") (BS.unpack s))
