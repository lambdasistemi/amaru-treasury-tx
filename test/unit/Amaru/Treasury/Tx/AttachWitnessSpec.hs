{- |
Module      : Amaru.Treasury.Tx.AttachWitnessSpec
Description : Unit tests for the attach-witness library
License     : Apache-2.0

Validates the decode/encode round-trip is byte-faithful, that
non-base16 input is rejected with a typed error, and that the witness
merge is a no-op when the input set is empty (so that operators who
re-run @attach-witness@ with no @--witness@ flags don't perturb the
unsigned bytes).
-}
module Amaru.Treasury.Tx.AttachWitnessSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.AttachWitness
    ( AttachError (..)
    , attachWitnesses
    , decodeUnsignedTxHex
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    , renderAttachError
    )

spec :: Spec
spec = describe "Amaru.Treasury.Tx.AttachWitness" $ do
    describe "decode / encode round-trip" $ do
        it "re-encodes the frozen swap fixture byte-identically" $ do
            hex <- BS.readFile fixtureSwapCbor
            case decodeUnsignedTxHex hex of
                Left err ->
                    fail $
                        "fixture failed to decode: "
                            <> show (renderAttachError err)
                Right tx ->
                    encodeSignedTxHex tx
                        `shouldBe` BS.filter (`BS.notElem` whitespaceBytes) hex

        it "tolerates a trailing newline in the input" $ do
            hex <- BS.readFile fixtureSwapCbor
            decodeUnsignedTxHex (hex <> "\n")
                `shouldSatisfy` isRight

    describe "attachWitnesses" $ do
        it "is a no-op for an empty witness set" $ do
            hex <- BS.readFile fixtureSwapCbor
            case decodeUnsignedTxHex hex of
                Left err ->
                    fail (show (renderAttachError err))
                Right tx ->
                    encodeSignedTxHex (attachWitnesses Set.empty tx)
                        `shouldBe` encodeSignedTxHex tx

    describe "decode error paths" $ do
        it "rejects invalid base16 with a typed error" $
            decodeUnsignedTxHex "deadbeefnothex"
                `shouldSatisfy` isAttachInvalidHex

        it "rejects valid base16 that is not a Conway tx" $
            decodeUnsignedTxHex "deadbeef"
                `shouldSatisfy` isAttachDecodeTxFailed

    describe "decodeVKeyWitnessHex (both wire shapes)" $ do
        -- Bare WitVKey: array(2) [bytes(32) vkey, bytes(64) sig].
        -- The shape hardware wallets and air-gapped signers usually
        -- emit. Starts with `82 5820 ...`.
        it "accepts the bare WitVKey shape" $
            decodeVKeyWitnessHex 1 sampleBareWitnessHex
                `shouldSatisfy` isRight

        -- Wrapped cardano-cli envelope: array(2) [0, WitVKey].
        -- The shape `cardano-cli transaction witness` emits inside
        -- its `TxWitness ConwayEra` JSON envelope. Starts with
        -- `82 00 82 5820 ...`.
        it "accepts the [0, WitVKey] wrapped shape" $
            decodeVKeyWitnessHex 1 ("8200" <> sampleBareWitnessHex)
                `shouldSatisfy` isRight

        it "rejects unsupported wrapper tags" $
            decodeVKeyWitnessHex 1 ("8201" <> sampleBareWitnessHex)
                `shouldSatisfy` isAttachDecodeWitnessFailed

        it "tags failures with the 1-based witness index" $
            case decodeVKeyWitnessHex 7 "deadbeef" of
                Left (AttachDecodeWitnessFailed ix _) -> ix `shouldBe` 7
                other -> fail (show other)

fixtureSwapCbor :: FilePath
fixtureSwapCbor = "test/fixtures/swap/expected.cbor"

whitespaceBytes :: ByteString
whitespaceBytes = BS.pack [0x20, 0x09, 0x0a, 0x0d]

isRight :: Either a b -> Bool
isRight = \case
    Right _ -> True
    Left _ -> False

isAttachInvalidHex :: Either AttachError a -> Bool
isAttachInvalidHex = \case
    Left (AttachInvalidHex _ _) -> True
    _ -> False

isAttachDecodeTxFailed :: Either AttachError a -> Bool
isAttachDecodeTxFailed = \case
    Left (AttachDecodeTxFailed _) -> True
    _ -> False

isAttachDecodeWitnessFailed :: Either AttachError a -> Bool
isAttachDecodeWitnessFailed = \case
    Left (AttachDecodeWitnessFailed _ _) -> True
    _ -> False

{- | A witness payload taken verbatim from the live mainnet canary
@dfd35553…@. Hex form is the bare @WitVKey@ shape — leading
@82 58 20@ marks an @array(2)@ whose first element is a 32-byte
verification key, followed by a 64-byte Ed25519 signature.
-}
sampleBareWitnessHex :: ByteString
sampleBareWitnessHex =
    "825820ab71c52f786d308c65cc4772eac66822e8cd169dc267a74f5ec9f7371895cdd9"
        <> "5840c2fad3efb7158e2b1f7b8c315e15fcdcd0a3bb97dda360363231c597c6b411f0"
        <> "6db63b82e03bbd10c3b5a8b0666d2687be54528e8e6e7e25c5bfcfdddc823705"
