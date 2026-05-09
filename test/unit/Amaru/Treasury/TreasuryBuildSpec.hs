{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.TreasuryBuildSpec
Description : Unit tests for the unified build pipeline
License     : Apache-2.0

The probe-driven network mismatch detection lives in
'Amaru.Treasury.Backend.N2C.findSocketMagic'. The probe
function is injected so we can assert the candidate-walk
behaviour without spinning up a real Unix socket — that
end-to-end verification is the manual T032 integration
test recorded in the PR description.
-}
module Amaru.Treasury.TreasuryBuildSpec (spec) where

import Control.Exception
    ( SomeException
    , displayException
    )
import Control.Tracer (Tracer (..))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldThrow
    )

import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , txBuildOptsP
    )
import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntentFile
    )
import Amaru.Treasury.TreasuryBuild
    ( TreasuryBuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.TreasuryBuild.ReportWriter
    ( ReportWriteError (..)
    , writeReportArtifact
    )
import Amaru.Treasury.TreasuryBuild.Trace
    ( BuildEvent (..)
    , renderBuildEvent
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend.N2C
    ( findSocketMagic
    , knownNetworkMagics
    , probeResultAccepted
    , stakeRewardLovelaceFromRewards
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseRewardAccountForNetwork
    )
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    )
import Cardano.Ledger.Coin (Coin (..))

spec :: Spec
spec = describe "Amaru.Treasury.TreasuryBuild" $ do
    describe "stakeRewardLovelaceFromRewards" $ do
        it "returns the selected account reward balance" $ do
            let AccountAddress _ (AccountId credential) =
                    fixtureRewardAccount
                rewards =
                    Map.singleton
                        credential
                        (Coin 12_345_678)
            stakeRewardLovelaceFromRewards
                credential
                rewards
                `shouldBe` 12_345_678

        it "treats a missing reward row as zero" $ do
            let AccountAddress _ (AccountId credential) =
                    fixtureRewardAccount
            stakeRewardLovelaceFromRewards
                credential
                Map.empty
                `shouldBe` 0

    describe "findSocketMagic" $ do
        it "returns the actual magic when the socket is on the wrong network" $ do
            -- Intent says mainnet; socket actually accepts preprod (1).
            let probe (NetworkMagic 1) = pure True
                probe _ = pure False
            r <- findSocketMagic probe "mainnet"
            r `shouldBe` 1

        it "returns 0 when no candidate magic is accepted" $ do
            let probe _ = pure False
            r <- findSocketMagic probe "mainnet"
            r `shouldBe` 0

        it "skips the intent's own network in the probe walk" $ do
            -- Track every magic we probe; assert mainnet is
            -- never asked (the intent already declares it).
            seenRef <- newIORef []
            let probe m = do
                    modifyIORef' seenRef (unNetworkMagic m :)
                    pure False
            _ <- findSocketMagic probe "mainnet"
            seen <- readIORef seenRef
            -- Order doesn't matter; just assert mainnet's
            -- magic (764824073) is not in the probe trail.
            (764_824_073 `elem` seen) `shouldBe` False

        it "stops at the first accepting probe" $ do
            -- Both preprod and preview accept; we should
            -- see only the first candidate hit (preprod).
            seenRef <- newIORef []
            let probe m = do
                    modifyIORef' seenRef (unNetworkMagic m :)
                    pure True
            r <- findSocketMagic probe "mainnet"
            seen <- readIORef seenRef
            length seen `shouldBe` 1
            r `shouldBe` 1

    describe "probeResultAccepted" $ do
        it "accepts a completed probe query" $
            probeResultAccepted (Just (Right ()))
                `shouldBe` True

        it "rejects a probe query timeout" $
            probeResultAccepted Nothing `shouldBe` False

    describe "knownNetworkMagics" $ do
        it "lists the three production-relevant networks" $ do
            map fst knownNetworkMagics
                `shouldBe` ["mainnet", "preprod", "preview"]
        it "uses the canonical magic numbers" $ do
            lookup "mainnet" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 764_824_073)
            lookup "preprod" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 1)
            lookup "preview" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 2)

    describe "tx-build CLI parser" $ do
        it "accepts an optional report path" $
            parseTxBuild
                [ "--intent"
                , "intent.json"
                , "--out"
                , "tx.cbor"
                , "--log"
                , "build.log"
                , "--report"
                , "tx-report.json"
                ]
                `shouldBe` Right
                    TxBuildOpts
                        { tboIntentPath = Just "intent.json"
                        , tboOutPath = Just "tx.cbor"
                        , tboLog = Just "build.log"
                        , tboReportPath = Just "tx-report.json"
                        }

        it "preserves no-report defaults" $
            parseTxBuild []
                `shouldBe` Right
                    TxBuildOpts
                        { tboIntentPath = Nothing
                        , tboOutPath = Nothing
                        , tboLog = Nothing
                        , tboReportPath = Nothing
                        }

    describe "report write traces" $ do
        it "renders report-write success with the destination path" $
            renderBuildEvent
                (TbeWroteReport "test/fixtures/swap/report.golden.json")
                `shouldBe` "tx-build: report -> test/fixtures/swap/report.golden.json"

        it "renders report-write failure with the failed path" $
            renderBuildEvent
                ( TbeReportWriteFailed
                    "missing/report.json"
                    "openBinaryFile: does not exist"
                )
                `shouldBe` "tx-build: REPORT WRITE FAILED missing/report.json: openBinaryFile: does not exist"

    describe "report writer" $
        it "reports the failed path when the report cannot be written" $ do
            result <-
                writeReportArtifact
                    (Tracer (const (pure ())))
                    "missing-parent/report.json"
                    "{}\n"
            case result of
                Left (ReportWriteError path message) -> do
                    path `shouldBe` "missing-parent/report.json"
                    message
                        `shouldContain` "missing-parent/report.json"
                Right () ->
                    expectationFailure
                        "expected report write failure"

    describe "runWithdraw" $
        it "reports missing required UTxOs before balancing" $ do
            some <-
                expectRightIO
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/withdraw/synthetic/intent.json"
            let ctx =
                    ChainContext
                        { ccPParams = emptyPParams
                        , ccUtxos = Map.empty
                        , ccEvaluateTx =
                            const (pure Map.empty)
                        }
            runFromIntent ctx some
                `shouldThrow` missingWithdrawUtxos

    describe "runFromIntent report data" $
        it "preserves swap no-report CBOR while exposing the final body" $ do
            some <-
                expectRightIO
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/swap/intent.json"
            fixture <- readSwapFixture "test/fixtures/swap"
            let ctx = toFrozenContext fixture
            result <- runFromIntent ctx some
            expected <-
                BS.readFile "test/fixtures/swap/expected.cbor"
            B16.encode (BSL.toStrict (tbrCborBytes result))
                `shouldBe` expected
            tbrFinalTxBody result `seq` pure ()

fixtureRewardAccount :: AccountAddress
fixtureRewardAccount =
    expectRight $
        parseRewardAccountForNetwork
            "mainnet"
            "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

missingWithdrawUtxos :: SomeException -> Bool
missingWithdrawUtxos =
    isInfixOf "runWithdraw: missing UTxOs"
        . displayException

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

expectRight :: (Show e) => Either e a -> a
expectRight =
    either
        ( error
            . ("unexpected Left: " <>)
            . show
        )
        id

parseTxBuild :: [String] -> Either String TxBuildOpts
parseTxBuild args =
    case execParserPure defaultPrefs (info txBuildOptsP mempty) args of
        Success opts -> Right opts
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"
