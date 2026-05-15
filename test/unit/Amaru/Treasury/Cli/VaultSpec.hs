{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.VaultSpec
Description : CLI parser tests for vault management commands
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.VaultSpec (spec) where

import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Vault
    ( VaultCreateOpts (..)
    , VaultSigningKeyInput (..)
    , vaultCreateOptsP
    )

spec :: Spec
spec = describe "Amaru.Treasury.Cli.Vault" $ do
    it "parses the top-level vault create command" $
        parseCmd
            [ "--network"
            , "preprod"
            , "vault"
            , "create"
            , "--signing-key-paste"
            , "--label"
            , "core_development"
            , "--description"
            , "core development payment key"
            , "--out"
            , "treasury.vault.age"
            , "--vault-passphrase-fd"
            , "9"
            , "--vault-work-factor"
            , "1"
            , "--force"
            ]
            `shouldBe` Right "vault-create"

    it "parses vault create options for hidden signing-key paste" $
        parseVaultCreateOpts
            [ "--signing-key-paste"
            , "--label"
            , "core_development"
            , "--out"
            , "treasury.vault.age"
            ]
            `shouldBe` Right
                VaultCreateOpts
                    { vcoSigningKeyInput = VaultSigningKeyPaste
                    , vcoLabel = "core_development"
                    , vcoDescription = Nothing
                    , vcoOutPath = "treasury.vault.age"
                    , vcoPassphraseFd = Nothing
                    , vcoWorkFactor = Nothing
                    , vcoForce = False
                    }

    it "parses signing-key stdin for non-interactive secret streams" $
        parseVaultCreateOpts
            [ "--signing-key-stdin"
            , "--label"
            , "core_development"
            , "--out"
            , "treasury.vault.age"
            ]
            `shouldBe` Right
                VaultCreateOpts
                    { vcoSigningKeyInput = VaultSigningKeyStdin
                    , vcoLabel = "core_development"
                    , vcoDescription = Nothing
                    , vcoOutPath = "treasury.vault.age"
                    , vcoPassphraseFd = Nothing
                    , vcoWorkFactor = Nothing
                    , vcoForce = False
                    }

    it "keeps explicit signing-key file import for compatibility" $
        parseVaultCreateOpts
            [ "--signing-key-file"
            , "payment.skey"
            , "--label"
            , "core_development"
            , "--out"
            , "treasury.vault.age"
            ]
            `shouldBe` Right
                VaultCreateOpts
                    { vcoSigningKeyInput =
                        VaultSigningKeyFile "payment.skey"
                    , vcoLabel = "core_development"
                    , vcoDescription = Nothing
                    , vcoOutPath = "treasury.vault.age"
                    , vcoPassphraseFd = Nothing
                    , vcoWorkFactor = Nothing
                    , vcoForce = False
                    }

parseCmd :: [String] -> Either String String
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success (_, CmdVaultCreate{}) -> Right "vault-create"
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseVaultCreateOpts :: [String] -> Either String VaultCreateOpts
parseVaultCreateOpts args =
    case execParserPure defaultPrefs (info vaultCreateOptsP mempty) args of
        Success parsed -> Right parsed
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"
