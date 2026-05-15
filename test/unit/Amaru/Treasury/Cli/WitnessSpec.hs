{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.WitnessSpec
Description : CLI parser tests for the witness command
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.WitnessSpec (spec) where

import Data.Text qualified as T
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
import Amaru.Treasury.Cli.Witness
    ( WitnessOpts (..)
    , witnessOptsP
    )

spec :: Spec
spec = describe "Amaru.Treasury.Cli.Witness" $ do
    it "parses the top-level witness command" $
        parseCmd
            [ "--network"
            , "preprod"
            , "witness"
            , "--tx"
            , "unsigned.cbor.hex"
            , "--vault"
            , "treasury.vault.age"
            , "--vault-passphrase-fd"
            , "9"
            , "--identity"
            , "core_development"
            , "--expected-key-hash"
            , keyHash
            , "--out"
            , "owner.witness.hex"
            , "--force"
            ]
            `shouldBe` Right "witness"

    it "parses witness options with pipe-friendly defaults" $
        parseWitnessOpts
            [ "--vault"
            , "treasury.vault.age"
            , "--identity"
            , "core_development"
            ]
            `shouldBe` Right
                WitnessOpts
                    { woTxPath = Nothing
                    , woVaultPath = "treasury.vault.age"
                    , woPassphraseFd = Nothing
                    , woIdentity = "core_development"
                    , woExpectedKeyHash = Nothing
                    , woAllowUnlistedKey = False
                    , woOutPath = Nothing
                    , woForce = False
                    }

    it "parses explicit unlisted-key acknowledgement" $
        parseWitnessOpts
            [ "--vault"
            , "treasury.vault.age"
            , "--vault-passphrase-fd"
            , "9"
            , "--identity"
            , keyHash
            , "--allow-unlisted-key"
            ]
            `shouldBe` Right
                WitnessOpts
                    { woTxPath = Nothing
                    , woVaultPath = "treasury.vault.age"
                    , woPassphraseFd = Just 9
                    , woIdentity = T.pack keyHash
                    , woExpectedKeyHash = Nothing
                    , woAllowUnlistedKey = True
                    , woOutPath = Nothing
                    , woForce = False
                    }

parseCmd :: [String] -> Either String String
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success (_, CmdWitness{}) -> Right "witness"
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseWitnessOpts :: [String] -> Either String WitnessOpts
parseWitnessOpts args =
    case execParserPure defaultPrefs (info witnessOptsP mempty) args of
        Success parsed -> Right parsed
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

keyHash :: String
keyHash = "00000000000000000000000000000000000000000000000000000000"
