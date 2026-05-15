{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.WitnessSpec
Description : Tests for vault-backed witness creation
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.WitnessSpec (spec) where

import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Tx.AttachWitness
    ( attachWitnesses
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , TxWitnessError (..)
    , createWitness
    , decodeWitnessTransaction
    , parseWitnessKeyHash
    , renderGuardKeyHash
    , renderTxWitnessError
    , validateWitnessRequest
    , witnessTransactionFacts
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    , decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Witness" $ do
    it "decodes raw unsigned Conway tx hex and extracts signing facts" $ do
        tx <- loadUnsignedTx
        keyHash <- parseFixtureKeyHash
        let facts = witnessTransactionFacts tx
        tsfRequiredSigners facts `shouldBe` Set.singleton keyHash
        tsfNetwork facts `shouldBe` Just Testnet
        tsfBodyHashHex facts `shouldSatisfy` (not . T.null)

    it "decodes cardano-cli Conway tx envelopes as transaction input" $ do
        raw <- BS.readFile (fixtureDir <> "/tx.body.json")
        case decodeWitnessTransaction raw of
            Left err -> fail (T.unpack (renderTxWitnessError err))
            Right tx ->
                tsfBodyHashHex (witnessTransactionFacts tx)
                    `shouldSatisfy` (not . T.null)

    it "rejects stale non-Conway envelopes" $
        decodeWitnessTransaction
            "{\"type\":\"Tx BabbageEra\",\"cborHex\":\"deadbeef\"}"
            `shouldSatisfy` isDecodeFailure

    it "accepts a selected identity present in required signer hashes" $ do
        ident <- loadIdentity "vault.clear.json" "core_development"
        tx <- loadUnsignedTx
        validateWitnessRequest
            Nothing
            False
            ident
            (witnessTransactionFacts tx)
            `shouldBe` Right ()

    it "rejects a selected identity missing from required signer hashes" $ do
        ident <- loadIdentity "vault.wrong-key.clear.json" "wrong_key"
        tx <- loadUnsignedTx
        validateWitnessRequest
            Nothing
            False
            ident
            (witnessTransactionFacts tx)
            `shouldSatisfy` isWrongKey

    it "rejects a selected identity on the wrong transaction network" $ do
        keyHash <- parseFixtureKeyHash
        ident <-
            loadIdentityBytes
                (mainnetVault (renderGuardKeyHash keyHash))
                "core_development"
        tx <- loadUnsignedTx
        validateWitnessRequest
            Nothing
            False
            ident
            (witnessTransactionFacts tx)
            `shouldBe` Left (TxWitnessNetworkMismatch "mainnet" Testnet)

    it "requires explicit approval when no required signers are declared" $ do
        tx <- loadTxWithoutRequiredSigners
        ident <- loadIdentity "vault.clear.json" "core_development"
        validateWitnessRequest
            Nothing
            False
            ident
            (witnessTransactionFacts tx)
            `shouldBe` Left TxWitnessUnlistedKeyRequiresApproval

    it
        "accepts an expected key hash when no required signers are declared"
        $ do
            tx <- loadTxWithoutRequiredSigners
            ident <- loadIdentity "vault.clear.json" "core_development"
            keyHash <- parseFixtureKeyHash
            validateWitnessRequest
                (Just keyHash)
                False
                ident
                (witnessTransactionFacts tx)
                `shouldBe` Right ()

    it
        "accepts explicit unlisted-key approval when no required signers are declared"
        $ do
            tx <- loadTxWithoutRequiredSigners
            ident <- loadIdentity "vault.clear.json" "core_development"
            validateWitnessRequest
                Nothing
                True
                ident
                (witnessTransactionFacts tx)
                `shouldBe` Right ()

    it "creates the same detached witness as cardano-cli" $ do
        ident <- loadIdentity "vault.clear.json" "core_development"
        tx <- loadUnsignedTx
        expected <- BS.readFile (fixtureDir <> "/witness.expected.hex")
        createWitness ident tx `shouldBe` Right expected

    it "creates a detached witness from an address extended signing key" $ do
        ident <- loadIdentityBytes addrXskVault "addr_xsk_fixture"
        tx <- loadUnsignedTx
        case createWitness ident tx of
            Left err -> expectationFailure (T.unpack (renderTxWitnessError err))
            Right witnessHex ->
                decodeVKeyWitnessHex 1 witnessHex
                    `shouldSatisfy` isRight

    it
        "attaches the produced witness into the expected signed transaction"
        $ do
            ident <- loadIdentity "vault.clear.json" "core_development"
            tx <- loadUnsignedTx
            expected <- BS.readFile (fixtureDir <> "/signed.expected.cbor.hex")
            case createWitness ident tx of
                Left err -> expectationFailure (T.unpack (renderTxWitnessError err))
                Right witnessHex ->
                    case decodeVKeyWitnessHex 1 witnessHex of
                        Left err ->
                            expectationFailure
                                (T.unpack (renderAttachError err))
                        Right wit ->
                            encodeSignedTxHex (attachWitnesses (Set.singleton wit) tx)
                                `shouldBe` expected

    it "renders key hashes as lowercase hex" $ do
        keyHash <- parseFixtureKeyHash
        expected <- T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
        renderGuardKeyHash keyHash `shouldBe` expected

loadUnsignedTx :: IO ConwayTx
loadUnsignedTx = do
    raw <- BS.readFile (fixtureDir <> "/unsigned.cbor.hex")
    case decodeWitnessTransaction raw of
        Left err -> fail (T.unpack (renderTxWitnessError err))
        Right tx -> pure tx

loadTxWithoutRequiredSigners :: IO ConwayTx
loadTxWithoutRequiredSigners = do
    raw <-
        BS.readFile "test/fixtures/106-cardano-cli-oracle/tx.body.cborHex"
    case decodeWitnessTransaction raw of
        Left err -> fail (T.unpack (renderTxWitnessError err))
        Right tx -> pure tx

loadIdentity :: FilePath -> T.Text -> IO VaultIdentity
loadIdentity file label = do
    raw <- BS.readFile (fixtureDir <> "/" <> file)
    loadIdentityBytes raw label

loadIdentityBytes :: BS.ByteString -> T.Text -> IO VaultIdentity
loadIdentityBytes raw label =
    case decodeWitnessVault raw >>= resolveVaultIdentity label of
        Left err -> fail (T.unpack (renderVaultError err))
        Right ident -> pure ident

parseFixtureKeyHash :: IO (KeyHash Guard)
parseFixtureKeyHash = do
    keyHash <- T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
    case parseWitnessKeyHash keyHash of
        Left err -> fail (T.unpack (renderTxWitnessError err))
        Right parsed -> pure parsed

isDecodeFailure :: Either TxWitnessError a -> Bool
isDecodeFailure = \case
    Left TxWitnessDecodeFailed{} -> True
    _ -> False

isWrongKey :: Either TxWitnessError a -> Bool
isWrongKey = \case
    Left TxWitnessSelectedKeyNotRequired{} -> True
    _ -> False

isRight :: Either a b -> Bool
isRight = \case
    Right _ -> True
    Left _ -> False

mainnetVault :: T.Text -> BS.ByteString
mainnetVault keyHash =
    TE.encodeUtf8 $
        "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"core_development\":{\"label\":\"core_development\",\"network\":\"mainnet\",\"keyHash\":\""
            <> keyHash
            <> "\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"582083c69e0facc37e938558a50b4335f0ca9855857bb5625f583a68464f54496bde\"}}}}}}"

addrXskVault :: BS.ByteString
addrXskVault =
    TE.encodeUtf8 $
        "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"addr_xsk_fixture\":{\"label\":\"addr_xsk_fixture\",\"network\":\"preprod\",\"keyHash\":\"62af57d18328e645219a713e8f63952beae9dbdd34b91d8c909e20c7\",\"source\":{\"kind\":\"cardano-addresses-addr-xsk\",\"bech32\":\""
            <> addrXsk
            <> "\"}}}}}"

addrXsk :: T.Text
addrXsk =
    "addr_xsk12pzle3450wwj2djlsvvpwdad0akp97ty70p4r57cjwctqdnr8pppcz4awzey5flzj3vc6utscunxufq7udekvu29ha5qgpk4rw6q6nudgm3llqq8ynvpedekfg5d8hczz6snz34lkf2heu3qkq2e0xzspg90765n"
