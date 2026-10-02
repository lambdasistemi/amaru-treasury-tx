{- |
Module      : Amaru.Treasury.IntentJSON.CommonSpec
Description : Totality of byte string to hash conversion
License     : Apache-2.0

'mkHash' turns a byte string into a hash for any algorithm:
a byte string whose length differs from the algorithm's
digest size yields a 'Left' naming the expected and the
actual length, a correct-length one yields the hash carrying
exactly those bytes. Both are exercised for a 28-byte and a
32-byte algorithm.

The public hex parsers built on it keep rejecting a
wrong-length hash field with their existing message.
-}
module Amaru.Treasury.IntentJSON.CommonSpec (spec) where

import Cardano.Crypto.Hash.Blake2b (Blake2b_224, Blake2b_256)
import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm (..)
    , hashSize
    , hashToBytes
    )
import Cardano.Ledger.Hashes (ADDRHASH, HASH)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.List (isSuffixOf)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Test.Hspec (Spec, describe, it)
import Test.QuickCheck
    ( Gen
    , Property
    , Testable
    , arbitrary
    , checkCoverage
    , choose
    , counterexample
    , cover
    , elements
    , forAll
    , oneof
    , property
    , suchThat
    , vectorOf
    , (===)
    )

import Amaru.Treasury.IntentJSON.Common
    ( mkHash
    , parseGuardKeyHash
    , parseRewardAccountForNetwork
    , parseTxIn
    )

spec :: Spec
spec = do
    describe "mkHash" $ do
        mkHashSpec (Proxy @Blake2b_224)
        mkHashSpec (Proxy @Blake2b_256)

    describe "wrong-length hash fields through the public parsers" $ do
        let txIdLength = digestLength (Proxy @HASH)
            keyHashLength = digestLength (Proxy @ADDRHASH)
        it "parseTxIn rejects a wrong-length txid" $
            forAllWrongLength txIdLength $ \bs ->
                parseTxIn (hexText bs <> "#0")
                    `leftIs` lengthMessage txIdLength bs
        it "parseGuardKeyHash rejects a wrong-length key hash" $
            forAllWrongLength keyHashLength $ \bs ->
                parseGuardKeyHash (hexText bs)
                    `leftIs` lengthMessage keyHashLength bs
        it "parseRewardAccountForNetwork rejects a wrong-length hash" $
            forAllWrongLength keyHashLength $ \bs ->
                parseRewardAccountForNetwork "mainnet" (hexText bs)
                    `leftIs` lengthMessage keyHashLength bs

{- | Totality and round-trip of 'mkHash' for one hash
algorithm, whose digest size is read from the algorithm.
-}
mkHashSpec :: forall h. (HashAlgorithm h) => Proxy h -> Spec
mkHashSpec p = describe (hashAlgorithmName p) $ do
    let d = digestLength p
    it "rejects every wrong length naming expected and actual" $
        forAllWrongLength d $ \bs ->
            case mkHash bs :: Either String (Hash h ()) of
                Left e ->
                    counterexample e $
                        property (lengthMessage d bs `isSuffixOf` e)
                Right h ->
                    counterexample ("unexpected Right " <> show h) $
                        property False
    it "round-trips every correct-length input" $
        forAll (genBytes d) $ \bs ->
            fmap hashToBytes (mkHash bs :: Either String (Hash h ()))
                === Right bs

digestLength :: (HashAlgorithm h) => proxy h -> Int
digestLength = fromIntegral . hashSize

lengthMessage :: Int -> ByteString -> String
lengthMessage expected bs =
    "expected "
        <> show expected
        <> " bytes, got "
        <> show (BS.length bs)

leftIs :: Either String a -> String -> Property
leftIs result expected = case result of
    Left e -> e === expected
    Right _ ->
        counterexample
            ("expected Left " <> show expected <> ", got Right")
            (property False)

{- | Quantify over byte strings of every length but the
digest size, requiring both shorter and longer inputs to be
exercised.
-}
forAllWrongLength
    :: (Testable prop) => Int -> (ByteString -> prop) -> Property
forAllWrongLength d prop =
    checkCoverage $
        forAll (genWrongLength d) $ \bs ->
            cover 30 (BS.length bs < d) "shorter than the digest" $
                cover 30 (BS.length bs > d) "longer than the digest" $
                    prop bs

genWrongLength :: Int -> Gen ByteString
genWrongLength d = do
    n <-
        oneof
            [ elements [0, d - 1, d + 1, 2 * d]
            , choose (0, 2 * d + 8)
            ]
            `suchThat` (/= d)
    genBytes n

genBytes :: Int -> Gen ByteString
genBytes n = BS.pack <$> vectorOf n arbitrary

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
