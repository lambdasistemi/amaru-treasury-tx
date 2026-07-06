{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.CoordinateSpec
Description : CLI parser and runner tests for coordinate
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.CoordinateSpec (spec) where

import Data.ByteString qualified as BS
import Data.IORef
    ( newIORef
    , readIORef
    , writeIORef
    )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    , renderFailure
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldContain
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Coordinate
    ( CoordinateDeps (..)
    , CoordinateOpts (..)
    , CoordinateReceipt (..)
    , coordinateOptsP
    , runCoordinateWith
    )
import Amaru.Treasury.Coordinator.Client
    ( EntryStatus (..)
    , Receipt (..)
    )
import Amaru.Treasury.Coordinator.Workflow
    ( CoordinationRequest (..)
    , CoordinationResult (..)
    , WorkflowConfig (..)
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    , decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    , vaultIdentityLabel
    )

spec :: Spec
spec = describe "Amaru.Treasury.Cli.Coordinate" $ do
    it "lists coordinate in top-level help" $ do
        renderHelp ["--help"] `shouldContain` "coordinate"

    it "parses coordinate options" $
        parseCoordinateOpts
            [ "--tx"
            , "unsigned.cbor.hex"
            , "--coordinator"
            , "https://coordinator.example/v1"
            , "--vault"
            , "treasury.vault.age"
            , "--vault-passphrase-fd"
            , "9"
            , "--requester"
            , "fuel"
            , "--owner"
            , "core_development"
            , "--owner"
            , "core_development"
            , "--fee-wallet-txin"
            , T.unpack feeTxIn
            , "--fee-wallet-address"
            , "addr_test1wallet"
            , "--fee-status-polls"
            , "7"
            ]
            `shouldBe` Right
                CoordinateOpts
                    { coTxPath = Just "unsigned.cbor.hex"
                    , coCoordinatorUrl = "https://coordinator.example/v1"
                    , coVaultPath = "treasury.vault.age"
                    , coPassphraseFd = Just 9
                    , coRequester = "fuel"
                    , coOwners = "core_development" :| ["core_development"]
                    , coFeeWalletTxIn = feeTxIn
                    , coFeeWalletAddress = "addr_test1wallet"
                    , coFeeStatusPolls = 7
                    }

    it "parses the top-level coordinate command" $
        parseCmd
            [ "--network"
            , "preprod"
            , "coordinate"
            , "--coordinator"
            , "https://coordinator.example"
            , "--vault"
            , "treasury.vault.age"
            , "--requester"
            , "fuel"
            , "--owner"
            , "core_development"
            , "--fee-wallet-txin"
            , T.unpack feeTxIn
            , "--fee-wallet-address"
            , "addr_test1wallet"
            ]
            `shouldBe` Right "coordinate"

    it "maps parsed options to workflow inputs through injected deps" $ do
        seen <- newIORef Nothing
        let deps =
                stubDeps
                    { cdRunWorkflow = \config request -> do
                        writeIORef seen (Just (config, request))
                        pure (Right sampleResult)
                    }
        receipt <- runCoordinateWith deps sampleOpts
        receipt
            `shouldBe` CoordinateReceipt
                { corEntryId = "entry-1"
                , corUploadedWitnesses = ["signer-1", "signer-2"]
                , corSubmittedTxId = "tx-1"
                , corFeePayment = Just sampleFeePayment
                , corFinalStatus = Ready
                }
        Just (config, request) <- readIORef seen
        config `shouldBe` WorkflowConfig{wcFeeStatusMaxPolls = 7}
        crUnsignedTx request `shouldBe` "deadbeef"
        vaultIdentityLabel (crRequester request) `shouldBe` "core_development"
        fmap vaultIdentityLabel (crOwners request)
            `shouldBe` "core_development" :| ["core_development"]

parseCoordinateOpts :: [String] -> Either String CoordinateOpts
parseCoordinateOpts args =
    case execParserPure defaultPrefs (info coordinateOptsP mempty) args of
        Success parsed -> Right parsed
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseCmd :: [String] -> Either String String
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success (_, CmdCoordinate{}) -> Right "coordinate"
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

renderHelp :: [String] -> String
renderHelp args =
    case execParserPure defaultPrefs opts args of
        Failure failure ->
            let (msg, _) = renderFailure failure "amaru-treasury-tx"
            in  msg
        Success{} -> ""
        CompletionInvoked{} -> ""

stubDeps :: CoordinateDeps IO
stubDeps =
    CoordinateDeps
        { cdReadTx = \path -> do
            path `shouldBe` Just "unsigned.cbor.hex"
            pure "deadbeef"
        , cdLoadIdentities = \coordinateOpts -> do
            coVaultPath coordinateOpts `shouldBe` "treasury.vault.age"
            coPassphraseFd coordinateOpts `shouldBe` Just 9
            requester <- loadFixtureIdentity "core_development"
            owner2 <- loadFixtureIdentity "core_development"
            pure (requester, requester :| [owner2])
        , cdRunWorkflow = \_ _ -> pure (Right sampleResult)
        }

sampleOpts :: CoordinateOpts
sampleOpts =
    CoordinateOpts
        { coTxPath = Just "unsigned.cbor.hex"
        , coCoordinatorUrl = "https://coordinator.example"
        , coVaultPath = "treasury.vault.age"
        , coPassphraseFd = Just 9
        , coRequester = "fuel"
        , coOwners = "core_development" :| ["core_development"]
        , coFeeWalletTxIn = feeTxIn
        , coFeeWalletAddress = "addr_test1wallet"
        , coFeeStatusPolls = 7
        }

sampleResult :: CoordinationResult
sampleResult =
    CoordinationResult
        { cwrEntryId = "entry-1"
        , cwrUploadedWitnesses = ["signer-1", "signer-2"]
        , cwrReceipt =
            Receipt
                { rTxId = "tx-1"
                , rSubmittedAt = "2026-07-06T12:34:56Z"
                }
        , cwrFinalStatus = Ready
        , cwrFeePayment = Just sampleFeePayment
        }

loadFixtureIdentity :: Text -> IO VaultIdentity
loadFixtureIdentity label = do
    raw <- BS.readFile "test/fixtures/118-vault-witness/vault.clear.json"
    case decodeWitnessVault raw >>= resolveVaultIdentity label of
        Left err -> fail (show (renderVaultError err))
        Right identity -> pure identity

sampleFeePayment :: Text
sampleFeePayment =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0"

feeTxIn :: Text
feeTxIn =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#1"
