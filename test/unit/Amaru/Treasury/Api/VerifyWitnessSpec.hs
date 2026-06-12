{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.VerifyWitnessSpec
Description : Unit tests for stateless witness verification
License     : Apache-2.0
-}
module Amaru.Treasury.Api.VerifyWitnessSpec (spec) where

import Data.Aeson
    ( Value
    , eitherDecodeStrict'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Crypto.DSIGN.Class (deriveVerKeyDSIGN)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (extractHash, hashAnnotated)
import Cardano.Ledger.Keys
    ( KeyRole (..)
    , VKey (..)
    , WitVKey (..)
    , signedDSIGN
    )
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Amaru.Treasury.Api.Types
    ( VerifyWitnessRequest (..)
    , VerifyWitnessResponse (..)
    )
import Amaru.Treasury.Api.VerifyWitness (verifyWitness)
import Amaru.Treasury.Tx.Witness
    ( TxWitnessError
    , createWitness
    , decodeCardanoCliSigningKey
    , decodeWitnessTransaction
    , renderTxWitnessError
    )
import Amaru.Treasury.Vault.Witness
    ( VaultError
    , VaultIdentity
    , decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    )

fixture118Dir :: FilePath
fixture118Dir = "test/fixtures/118-vault-witness"

fixture106Tx :: FilePath
fixture106Tx = "test/fixtures/106-cardano-cli-oracle/tx.body.cborHex"

spec :: Spec
spec = describe "Amaru.Treasury.Api.VerifyWitness" $ do
    it "accepts a matching detached witness for a required signer" $ do
        unsignedTx <- loadText (fixture118Dir <> "/unsigned.cbor.hex")
        witness <- loadText (fixture118Dir <> "/witness.expected.hex")
        keyHash <- loadText (fixture118Dir <> "/key.hash")

        verifyWitness (VerifyWitnessRequest unsignedTx witness)
            `shouldBe` VerifyWitnessResponse
                { vwrOk = True
                , vwrSignerKeyHash = Just keyHash
                , vwrReason = Nothing
                }

    it "rejects a valid witness whose vkey is not required" $ do
        unsignedTx <- loadText (fixture118Dir <> "/unsigned.cbor.hex")
        tx118 <- loadTx (fixture118Dir <> "/unsigned.cbor.hex")
        witness <- wrongPaymentWitnessText tx118

        let response =
                verifyWitness (VerifyWitnessRequest unsignedTx witness)

        vwrOk response `shouldBe` False
        vwrSignerKeyHash response `shouldBe` Nothing
        vwrReason response `shouldSatisfy` reasonContains "required signer"

    it "rejects a required vkey whose signature is over another body" $ do
        unsignedTx <- loadText (fixture118Dir <> "/unsigned.cbor.hex")
        tx106 <- loadTx fixture106Tx
        identity <- loadIdentity "vault.clear.json" "core_development"
        witness <- createWitnessText identity tx106

        let response =
                verifyWitness (VerifyWitnessRequest unsignedTx witness)

        vwrOk response `shouldBe` False
        vwrSignerKeyHash response `shouldBe` Nothing
        vwrReason response `shouldSatisfy` reasonContains "signature"

    it "rejects malformed witness hex as data" $ do
        unsignedTx <- loadText (fixture118Dir <> "/unsigned.cbor.hex")
        let response =
                verifyWitness (VerifyWitnessRequest unsignedTx "deadbeef")

        vwrOk response `shouldBe` False
        vwrSignerKeyHash response `shouldBe` Nothing
        vwrReason response `shouldSatisfy` reasonContains "malformed"

loadText :: FilePath -> IO Text
loadText path = T.strip <$> TIO.readFile path

loadTx :: FilePath -> IO ConwayTx
loadTx path = do
    raw <- BS.readFile path
    either failWitness pure (decodeWitnessTransaction raw)

loadIdentity :: FilePath -> Text -> IO VaultIdentity
loadIdentity file label = do
    raw <- BS.readFile (fixture118Dir <> "/" <> file)
    loadIdentityBytes raw label

loadIdentityBytes :: BS.ByteString -> Text -> IO VaultIdentity
loadIdentityBytes raw label =
    either failVault pure $
        decodeWitnessVault raw >>= resolveVaultIdentity label

wrongPaymentWitnessText :: ConwayTx -> IO Text
wrongPaymentWitnessText tx = do
    keyEnvelope <- loadCardanoCliKey "wrong-payment.skey"
    signKey <-
        either failWitness pure (decodeCardanoCliSigningKey keyEnvelope)
    let vkey = VKey (deriveVerKeyDSIGN signKey) :: VKey Witness
        bodyHash = extractHash (hashAnnotated (tx ^. bodyTxL))
        witness = WitVKey vkey (signedDSIGN signKey bodyHash)
    pure $
        TE.decodeUtf8 $
            B16.encode $
                BSL.toStrict $
                    serialize (eraProtVerLow @ConwayEra) witness

createWitnessText :: VaultIdentity -> ConwayTx -> IO Text
createWitnessText identity tx =
    TE.decodeUtf8 <$> either failWitness pure (createWitness identity tx)

loadCardanoCliKey :: FilePath -> IO Value
loadCardanoCliKey file = do
    raw <- BS.readFile (fixture118Dir <> "/" <> file)
    case eitherDecodeStrict' raw of
        Right value -> pure value
        Left err -> fail err

reasonContains :: Text -> Maybe Text -> Bool
reasonContains needle =
    maybe False (T.isInfixOf needle . T.toLower)

failWitness :: TxWitnessError -> IO a
failWitness err =
    expectationFailure (T.unpack (renderTxWitnessError err))
        *> fail "witness"

failVault :: VaultError -> IO a
failVault err =
    expectationFailure (T.unpack (renderVaultError err)) *> fail "vault"
