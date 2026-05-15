{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Vault.AgeSpec
Description : Tests for native age vault encryption
License     : Apache-2.0
-}
module Amaru.Treasury.Vault.AgeSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Crypto.Age.Scrypt (WorkFactor)

import Amaru.Treasury.Vault.Age
    ( VaultPassphrase
    , decryptAgeVault
    , defaultVaultWorkFactor
    , encryptAgeVault
    , mkVaultPassphrase
    , parseVaultWorkFactor
    , renderAgeVaultError
    )

spec :: Spec
spec = describe "Amaru.Treasury.Vault.Age" $ do
    it "round-trips vault cleartext through age scrypt encryption" $ do
        workFactor <- parseWorkFactor 1
        passphrase <- parsePassphrase "correct horse battery staple"
        encrypted <- encrypt workFactor passphrase cleartextVault
        encrypted `shouldSatisfy` (/= cleartextVault)
        decryptAgeVault workFactor passphrase encrypted
            `shouldBe` Right cleartextVault

    it "fails with a redacted diagnostic for the wrong passphrase" $ do
        workFactor <- parseWorkFactor 1
        passphrase <- parsePassphrase "correct horse battery staple"
        wrong <- parsePassphrase "wrong passphrase"
        encrypted <- encrypt workFactor passphrase cleartextVault
        case decryptAgeVault workFactor wrong encrypted of
            Right plaintext ->
                expectationFailure
                    ("unexpected decrypt: " <> show plaintext)
            Left err -> do
                renderAgeVaultError err
                    `shouldSatisfy` T.isInfixOf "failed to decrypt age vault"
                renderAgeVaultError err
                    `shouldSatisfy` not . T.isInfixOf "correct horse"
                renderAgeVaultError err
                    `shouldSatisfy` not . T.isInfixOf secretSigningKey

    it "rejects malformed age files without dumping the input" $ do
        workFactor <- parseWorkFactor 1
        passphrase <- parsePassphrase "correct horse battery staple"
        let malformed = "not an age vault: " <> cleartextVault
        case decryptAgeVault workFactor passphrase malformed of
            Right plaintext ->
                expectationFailure
                    ("unexpected decrypt: " <> show plaintext)
            Left err ->
                renderAgeVaultError err
                    `shouldSatisfy` not . T.isInfixOf secretSigningKey

    it "rejects empty passphrases" $
        case mkVaultPassphrase "" of
            Left{} -> pure ()
            Right{} -> expectationFailure "empty passphrase was accepted"

    it "rejects work factors above the supported witness cap" $
        case parseVaultWorkFactor (defaultVaultWorkFactor + 1) of
            Left{} -> pure ()
            Right{} ->
                expectationFailure
                    "unsupported work factor was accepted"

parseWorkFactor :: Int -> IO WorkFactor
parseWorkFactor n =
    case parseVaultWorkFactor n of
        Left err -> fail (T.unpack (renderAgeVaultError err))
        Right parsed -> pure parsed

parsePassphrase :: BS.ByteString -> IO VaultPassphrase
parsePassphrase raw =
    case mkVaultPassphrase raw of
        Left err -> fail (T.unpack (renderAgeVaultError err))
        Right parsed -> pure parsed

encrypt
    :: WorkFactor -> VaultPassphrase -> BS.ByteString -> IO BS.ByteString
encrypt workFactor passphrase payload = do
    result <- encryptAgeVault workFactor passphrase payload
    case result of
        Left err -> fail (T.unpack (renderAgeVaultError err))
        Right encrypted -> pure encrypted

secretSigningKey :: T.Text
secretSigningKey =
    "582083c69e0facc37e938558a50b4335f0ca9855857bb5625f583a68464f54496bde"

cleartextVault :: BS.ByteString
cleartextVault =
    "{\"amaruTreasuryWitnessVault\":{\"version\":1,\"identities\":{\"core_development\":{\"label\":\"core_development\",\"network\":\"preprod\",\"keyHash\":\"f3af2802b3df828e7b2f2c60d6d63cd0d0697dee1d551c6a7087a826\",\"source\":{\"kind\":\"cardano-cli-skey\",\"keyEnvelope\":{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"582083c69e0facc37e938558a50b4335f0ca9855857bb5625f583a68464f54496bde\"}}}}}}"
