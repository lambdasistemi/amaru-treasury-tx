{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Vault.Age
Description : Native age encryption for witness vaults
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module is the only place where the CLI depends on the Haskell
@age@ package. It encrypts and decrypts binary age files with an
scrypt passphrase recipient and returns redacted errors.
-}
module Amaru.Treasury.Vault.Age
    ( AgeVaultError (..)
    , VaultPassphrase
    , decryptAgeVault
    , defaultVaultWorkFactor
    , encryptAgeVault
    , mkVaultPassphrase
    , parseVaultWorkFactor
    , renderAgeVaultError
    ) where

import Control.Monad.Trans.Except (runExceptT)
import Crypto.Age.Buffered qualified as Age
import Crypto.Age.Identity
    ( Identity (..)
    , ScryptIdentity (..)
    )
import Crypto.Age.Recipient
    ( Recipients (..)
    , ScryptRecipient (..)
    )
import Crypto.Age.Scrypt
    ( Passphrase (..)
    , WorkFactor
    , bytesToSalt
    , mkWorkFactor
    )
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T

-- | Default age scrypt work factor for operator-created vaults.
defaultVaultWorkFactor :: Int
defaultVaultWorkFactor = 18

-- | Secret passphrase wrapper. The constructor is intentionally hidden.
newtype VaultPassphrase = VaultPassphrase Passphrase
    deriving stock (Eq)

-- | Redacted age vault failures.
data AgeVaultError
    = AgeVaultEmptyPassphrase
    | AgeVaultInvalidWorkFactor !Int
    | AgeVaultSaltFailure
    | AgeVaultEncryptFailure
    | AgeVaultDecryptFailure
    deriving stock (Eq, Show)

-- | Build a passphrase from bytes read at a safe CLI boundary.
mkVaultPassphrase
    :: ByteString -> Either AgeVaultError VaultPassphrase
mkVaultPassphrase raw
    | BS.null raw = Left AgeVaultEmptyPassphrase
    | otherwise =
        Right $
            VaultPassphrase $
                Passphrase (BA.convert raw)

-- | Parse the supported age scrypt work factor range.
parseVaultWorkFactor :: Int -> Either AgeVaultError WorkFactor
parseVaultWorkFactor raw
    | raw < 1 || raw > defaultVaultWorkFactor =
        Left (AgeVaultInvalidWorkFactor raw)
    | otherwise =
        maybe
            (Left (AgeVaultInvalidWorkFactor raw))
            Right
            (mkWorkFactor (fromIntegral raw))

-- | Encrypt cleartext vault bytes as a binary age file.
encryptAgeVault
    :: WorkFactor
    -> VaultPassphrase
    -> ByteString
    -> IO (Either AgeVaultError ByteString)
encryptAgeVault workFactor (VaultPassphrase passphrase) plaintext = do
    saltBytes <- getRandomBytes 16
    case bytesToSalt saltBytes of
        Nothing -> pure (Left AgeVaultSaltFailure)
        Just salt -> do
            result <-
                runExceptT $
                    Age.encrypt
                        ( RecipientsScrypt
                            ScryptRecipient
                                { srPassphrase = passphrase
                                , srSalt = salt
                                , srWorkFactor = workFactor
                                }
                        )
                        plaintext
            pure $
                either
                    (const (Left AgeVaultEncryptFailure))
                    Right
                    result

-- | Decrypt binary age vault bytes in memory.
decryptAgeVault
    :: WorkFactor
    -> VaultPassphrase
    -> ByteString
    -> Either AgeVaultError ByteString
decryptAgeVault maxWorkFactor (VaultPassphrase passphrase) ciphertext =
    either
        (const (Left AgeVaultDecryptFailure))
        Right
        (Age.decrypt identities ciphertext)
  where
    identities :: NonEmpty Identity
    identities =
        IdentityScrypt
            ScryptIdentity
                { siPassphrase = passphrase
                , siMaxWorkFactor = maxWorkFactor
                }
            :| []

-- | Render a redacted operator diagnostic for age vault errors.
renderAgeVaultError :: AgeVaultError -> Text
renderAgeVaultError = \case
    AgeVaultEmptyPassphrase ->
        "vault passphrase is empty"
    AgeVaultInvalidWorkFactor raw ->
        "invalid age scrypt work factor "
            <> T.pack (show raw)
            <> " (supported range: 1-"
            <> T.pack (show defaultVaultWorkFactor)
            <> ")"
    AgeVaultSaltFailure ->
        "failed to generate age vault salt"
    AgeVaultEncryptFailure ->
        "failed to encrypt age vault"
    AgeVaultDecryptFailure ->
        "failed to decrypt age vault"
