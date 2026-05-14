{- |
Module      : Amaru.Treasury.Tx.SubmitSpec
Description : Unit tests for the @submit@ output renderer
License     : Apache-2.0

Pins the on-wire shape of 'renderTxId' so the @submit@ CLI's stdout
stays a single line of bare lowercase base16 hex (64 chars). The CLI
contract — bare hex on stdout, structured prefix on stderr — depends
on this renderer, so a typo in the helper would silently re-introduce
the old @TxId {unTxId = SafeHash …}@ noise.
-}
module Amaru.Treasury.Tx.SubmitSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..))

import Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , renderSubmitOutcome
    , renderTxId
    )

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Submit" $ do
    describe "renderTxId" $ do
        it "round-trips the 32-byte hash as lowercase base16" $
            renderTxId sampleTxId `shouldBe` sampleHex
        it "matches ^[0-9a-f]{64}$" $
            renderTxId sampleTxId `shouldSatisfy` isLowerHex64
    describe "renderSubmitOutcome" $ do
        it "embeds the same bare hex on the accepted line" $
            renderSubmitOutcome (SubmitAccepted sampleTxId)
                `shouldBe` ("submit: accepted " <> sampleHex)

-- A deterministic 32-byte sample: 0x00, 0x01, …, 0x1f.
sampleBytes :: ByteString
sampleBytes = BS.pack [0 .. 31]

sampleHex :: Text
sampleHex =
    "000102030405060708090a0b0c0d0e0f"
        <> "101112131415161718191a1b1c1d1e1f"

sampleTxId :: TxId
sampleTxId =
    TxId
        ( unsafeMakeSafeHash
            ( fromMaybe
                (error "SubmitSpec: 32-byte hash")
                (hashFromBytes sampleBytes)
            )
        )

isLowerHex64 :: Text -> Bool
isLowerHex64 t =
    T.length t == 64
        && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) t
