{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Vault.WitnessSpec
Description : Tests for witness vault schema parsing
License     : Apache-2.0
-}
module Amaru.Treasury.Vault.WitnessSpec (spec) where

import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (..))

import Amaru.Treasury.Vault.Witness
    ( SigningSource (..)
    , VaultError (..)
    , VaultIdentitySpec (..)
    , decodeWitnessVault
    , encodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    , vaultIdentityKeyHash
    , vaultIdentityKeyHashText
    , vaultIdentityNetwork
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

spec :: Spec
spec = describe "Amaru.Treasury.Vault.Witness" $ do
    it "decodes a v1 cleartext vault and resolves an identity by label" $ do
        vaultBytes <- BS.readFile (fixtureDir <> "/vault.clear.json")
        keyHash <- T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
        case decodeWitnessVault vaultBytes of
            Left err -> fail (T.unpack (renderVaultError err))
            Right vault -> do
                case resolveVaultIdentity "core_development" vault of
                    Left err -> fail (T.unpack (renderVaultError err))
                    Right ident -> do
                        vaultIdentityNetwork ident `shouldBe` "preprod"
                        vaultIdentityKeyHashText ident `shouldBe` keyHash

    it "resolves an identity by key hash" $ do
        vaultBytes <- BS.readFile (fixtureDir <> "/vault.clear.json")
        keyHash <- T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
        case decodeWitnessVault vaultBytes >>= resolveVaultIdentity keyHash of
            Left err -> fail (T.unpack (renderVaultError err))
            Right ident ->
                vaultIdentityKeyHashText ident `shouldBe` keyHash

    it "encodes a vault created from an imported cardano-cli signing key" $ do
        keyHashText <-
            T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
        keyHash <-
            case parseFixtureKeyHash keyHashText of
                Left err -> fail err
                Right parsed -> pure parsed
        let encoded =
                encodeWitnessVault
                    ( VaultIdentitySpec
                        { visLabel = "core_development"
                        , visNetwork = "preprod"
                        , visKeyHash = keyHash
                        , visDescription =
                            Just "core development payment key"
                        , visSource =
                            CardanoCliSKey
                                ( object
                                    [ "type"
                                        .= ( "PaymentSigningKeyShelley_ed25519" :: T.Text
                                           )
                                    , "description"
                                        .= ("Payment Signing Key" :: T.Text)
                                    , "cborHex"
                                        .= ( "582083c69e0facc37e938558a50b4335f0ca9855857bb5625f583a68464f54496bde"
                                                :: T.Text
                                           )
                                    ]
                                )
                        }
                        :| []
                    )
        case decodeWitnessVault encoded
            >>= resolveVaultIdentity "core_development" of
            Left err -> fail (T.unpack (renderVaultError err))
            Right ident -> do
                vaultIdentityNetwork ident `shouldBe` "preprod"
                vaultIdentityKeyHashText ident `shouldBe` keyHashText

    it "rejects unsupported vault versions" $
        decodeWitnessVault
            "{\"amaruTreasuryWitnessVault\":{\"version\":2,\"identities\":{}}}"
            `shouldBe` Left (VaultUnsupportedVersion 2)

    it "rejects duplicate key hashes" $ do
        keyHash <- T.strip . T.pack <$> readFile (fixtureDir <> "/key.hash")
        decodeWitnessVault (duplicateVault keyHash)
            `shouldSatisfy` isDuplicateKeyHash

    it "rejects missing identities with non-secret labels only" $ do
        vaultBytes <- BS.readFile (fixtureDir <> "/vault.clear.json")
        case decodeWitnessVault vaultBytes >>= resolveVaultIdentity "missing" of
            Left err -> do
                renderVaultError err
                    `shouldSatisfy` T.isInfixOf "missing"
                renderVaultError err
                    `shouldSatisfy` T.isInfixOf "core_development"
            Right ident -> fail ("unexpected identity: " <> show ident)

    it "rejects malformed key hashes" $
        decodeWitnessVault
            "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"bad\":{\"label\":\"bad\",\"network\":\"preprod\",\"keyHash\":\"abcd\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"secret\"}}}}}}"
            `shouldSatisfy` isMalformedKeyHash

    it "redacts secret-looking values from diagnostics" $ do
        let secret =
                "5820aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            bad =
                TE.encodeUtf8 $
                    "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"bad\":{\"label\":\"bad\",\"network\":\"preprod\",\"keyHash\":\""
                        <> secret
                        <> "\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\""
                        <> secret
                        <> "\"}}}}}}"
        case decodeWitnessVault bad of
            Left err ->
                renderVaultError err
                    `shouldSatisfy` not . T.isInfixOf secret
            Right vault -> fail ("unexpected vault: " <> show vault)

isMalformedKeyHash :: Either VaultError a -> Bool
isMalformedKeyHash = \case
    Left VaultMalformedKeyHash{} -> True
    _ -> False

isDuplicateKeyHash :: Either VaultError a -> Bool
isDuplicateKeyHash = \case
    Left VaultDuplicateKeyHash{} -> True
    _ -> False

duplicateVault :: T.Text -> BS.ByteString
duplicateVault keyHash =
    TE.encodeUtf8 $
        "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"first\":{\"label\":\"first\",\"network\":\"preprod\",\"keyHash\":\""
            <> keyHash
            <> "\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"secret\"}}},\"second\":{\"label\":\"second\",\"network\":\"preprod\",\"keyHash\":\""
            <> keyHash
            <> "\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"secret\"}}}}}}"

parseFixtureKeyHash :: T.Text -> Either String (KeyHash Guard)
parseFixtureKeyHash keyHash =
    case decodeWitnessVault (minimalVault keyHash) of
        Left err -> Left (T.unpack (renderVaultError err))
        Right vault ->
            case resolveVaultIdentity "core_development" vault of
                Left err -> Left (T.unpack (renderVaultError err))
                Right ident -> Right (vaultIdentityKeyHash ident)

minimalVault :: T.Text -> BS.ByteString
minimalVault keyHash =
    TE.encodeUtf8 $
        "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"core_development\":{\"label\":\"core_development\",\"network\":\"preprod\",\"keyHash\":\""
            <> keyHash
            <> "\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"secret\"}}}}}}"
