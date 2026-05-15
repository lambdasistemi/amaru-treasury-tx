{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.BuildSpec
Description : Unit tests for the unified build pipeline
License     : Apache-2.0

The probe-driven network mismatch detection lives in
'Amaru.Treasury.Backend.N2C.findSocketMagic'. The probe
function is injected so we can assert the candidate-walk
behaviour without spinning up a real Unix socket — that
end-to-end verification is the manual T032 integration
test recorded in the PR description.
-}
module Amaru.Treasury.BuildSpec (spec) where

import Control.Exception
    ( SomeException
    , displayException
    , evaluate
    , mapException
    , throw
    , throwIO
    , try
    )
import Control.Tracer (Tracer (..))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldReturn
    , shouldSatisfy
    , shouldThrow
    )

import Amaru.Treasury.Build
    ( BuildAction (..)
    , BuildDiagnostic (..)
    , BuildError (..)
    , BuildErrorContext (..)
    , BuildException (..)
    , BuildFailurePhase (..)
    , BuildResult (..)
    , buildErrorCode
    , buildErrorFromTxBuildError
    , mapBuildExceptionContext
    , renderBuildError
    , runFromIntent
    , runFromIntentEither
    , withBuildExceptionContext
    )
import Amaru.Treasury.Build.ReportWriter
    ( ReportWriteError (..)
    , writeReportArtifact
    )
import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    , renderBuildEvent
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
import Amaru.Treasury.Report
    ( BuildFailure (..)
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    , renderFailure
    )
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend
    ( Provider (..)
    , rewardAccountLovelace
    , singleShotWithAcquired
    )
import Amaru.Treasury.Backend.N2C
    ( findSocketMagic
    , knownNetworkMagics
    , probeResultAccepted
    )
import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseRewardAccountForNetwork
    )
import Cardano.Ledger.Address
    ( AccountAddress
    )
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TxBody)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.Balance
    ( BalanceError (..)
    )
import Cardano.Node.Client.TxBuild qualified as TxBuild
import Lens.Micro ((^.))

spec :: Spec
spec = describe "Amaru.Treasury.Build" $ do
    describe "rewardAccountLovelace" $ do
        it "returns the selected account reward balance through Provider" $ do
            let rewards =
                    Map.singleton
                        fixtureRewardAccount
                        (Coin 12_345_678)
            rewardAccountLovelace
                (rewardProvider rewards)
                fixtureRewardAccount
                `shouldReturn` 12_345_678

        it "treats a missing Provider reward row as zero" $ do
            rewardAccountLovelace
                (rewardProvider Map.empty)
                fixtureRewardAccount
                `shouldReturn` 0

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
        it "lists public networks plus the local devnet" $ do
            map fst knownNetworkMagics
                `shouldBe` ["mainnet", "preprod", "preview", "devnet"]
        it "uses the canonical magic numbers" $ do
            lookup "mainnet" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 764_824_073)
            lookup "preprod" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 1)
            lookup "preview" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 2)
            lookup "devnet" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 42)

    describe "global network parser" $ do
        it "accepts the local devnet network name" $ do
            case parseCli ["--network", "devnet", "tx-build"] of
                Right (g, CmdTxBuild _) -> do
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    resolveNetworkName g `shouldBe` Right "devnet"
                Right _ ->
                    expectationFailure "expected tx-build command"
                Left e -> expectationFailure e

        it "maps network magic 42 back to the local devnet name" $ do
            case parseCli ["--network-magic", "42", "tx-build"] of
                Right (g, CmdTxBuild _) -> do
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    resolveNetworkName g `shouldBe` Right "devnet"
                Right _ ->
                    expectationFailure "expected tx-build command"
                Left e -> expectationFailure e

        it "mentions devnet in unknown network errors" $
            case parseCli ["--network", "localnet", "tx-build"] of
                Left err ->
                    err `shouldContain` "devnet"
                Right _ ->
                    expectationFailure "expected parse failure"

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

        it "accepts report stdout alias" $
            parseTxBuild ["--report", "-"]
                `shouldBe` Right
                    TxBuildOpts
                        { tboIntentPath = Nothing
                        , tboOutPath = Nothing
                        , tboLog = Nothing
                        , tboReportPath = Just "-"
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
                (BuildEventWroteReport "test/fixtures/swap/report.golden.json")
                `shouldBe` "tx-build: report -> test/fixtures/swap/report.golden.json"

        it "renders report-write failure with the failed path" $
            renderBuildEvent
                ( BuildEventReportWriteFailed
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

    describe "normalized build diagnostics" $ do
        it
            "renders insufficient-fee failures with stable code and labeled fields"
            $ do
                let err =
                        buildErrorFromTxBuildError
                            BuildActionSwap
                            BuildPhaseBuild
                            ( TxBuild.BalanceFailed
                                (InsufficientFee (Coin 1_200) (Coin 700))
                                :: TxBuild.BuildError ()
                            )
                    message = renderBuildError err
                buildErrorCode err
                    `shouldBe` "insufficient-fee-capacity"
                message `shouldSatisfy` T.isInfixOf "required lovelace: 1200"
                message `shouldSatisfy` T.isInfixOf "available lovelace: 700"
                T.unpack message
                    `shouldSatisfy` (not . isInfixOf "BalanceFailed")

        it "renders fee convergence failures with stable retry guidance" $ do
            let err =
                    buildErrorFromTxBuildError
                        BuildActionSwap
                        BuildPhaseBuild
                        ( TxBuild.BalanceFailed FeeNotConverged
                            :: TxBuild.BuildError ()
                        )
            buildErrorCode err
                `shouldBe` "fee-not-converged"
            renderBuildError err
                `shouldSatisfy` T.isInfixOf "retry with fresh chain state"

        it "feeds report failures with the normalized code and message" $ do
            let err =
                    BuildError
                        { beAction = BuildActionSwap
                        , bePhase = BuildPhaseFeeAlignment
                        , beContext = []
                        , beDiagnostic =
                            DiagnosticFeeAlignmentFailed
                                "fee did not converge"
                        }
                failure =
                    BuildFailure
                        { bfCode = buildErrorCode err
                        , bfMessage = renderBuildError err
                        }
            bfCode failure `shouldBe` "fee-alignment-failed"
            bfMessage failure
                `shouldSatisfy` T.isInfixOf "fee did not converge"

        it "adds structured context with mapException for pure exceptions" $ do
            let ctx = ContextBuildPhase BuildPhaseFeeAlignment
                base =
                    BuildException
                        BuildError
                            { beAction = BuildActionSwap
                            , bePhase = BuildPhaseBuild
                            , beContext = []
                            , beDiagnostic =
                                DiagnosticFeeAlignmentFailed "boom"
                            }
                expr =
                    mapException
                        (mapBuildExceptionContext ctx)
                        (throw base :: ())
            result <-
                try (evaluate expr)
                    :: IO (Either BuildException ())
            case result of
                Left (BuildException err) ->
                    beContext err `shouldBe` [ctx]
                Right () ->
                    expectationFailure
                        "expected BuildException"

        it "adds structured context around IO exceptions" $ do
            let ctx = ContextReportDestination "report.json"
                base =
                    BuildException
                        BuildError
                            { beAction = BuildActionSwap
                            , bePhase = BuildPhaseBuild
                            , beContext = []
                            , beDiagnostic =
                                DiagnosticFeeAlignmentFailed "boom"
                            }
            result <-
                try $
                    withBuildExceptionContext ctx $
                        throwIO base
                    :: IO (Either BuildException ())
            case result of
                Left (BuildException err) ->
                    beContext err `shouldBe` [ctx]
                Right () ->
                    expectationFailure
                        "expected BuildException"

        it "does not keep the legacy raw build-failed strings" $ do
            source <- readFile "lib/Amaru/Treasury/Build.hs"
            source
                `shouldSatisfy` (not . isInfixOf "runSwap: build failed")
            source
                `shouldSatisfy` (not . isInfixOf "runDisburse: build failed")
            source
                `shouldSatisfy` (not . isInfixOf "runWithdraw: build failed")

    describe "runWithdraw" $ do
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

        it "returns typed missing UTxO diagnostics on the Either path" $ do
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
            result <- runFromIntentEither ctx some
            case result of
                Left err -> do
                    buildErrorCode err `shouldBe` "missing-utxos"
                    T.unpack (renderBuildError err)
                        `shouldSatisfy` (not . isInfixOf "runWithdraw")
                Right{} ->
                    expectationFailure "expected typed missing-UTxO error"

        it
            "balances the reward withdrawal as value supplied by the transaction"
            $ do
                some <-
                    expectRightIO
                        =<< decodeTreasuryIntentFile
                            "test/fixtures/withdraw/synthetic/intent.json"
                fixture <- readSwapFixture "test/fixtures/withdraw/synthetic"
                result <- runFromIntent (toFrozenContext fixture) some
                let rewardLovelace = 12_500_000_000
                    inputLovelace =
                        sum (txOutLovelace . snd <$> brWalletInputs result)
                    outputLovelace =
                        txBodyOutputLovelace (brFinalTxBody result)
                    Coin feeLovelace =
                        brFeeLovelace result
                inputLovelace + rewardLovelace
                    `shouldBe` outputLovelace + feeLovelace

    describe "runSwap" $
        it "returns a normalized swap runner failure on the Either path" $ do
            some <-
                expectRightIO
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/swap/intent.json"
            let ctx =
                    ChainContext
                        { ccPParams = emptyPParams
                        , ccUtxos = Map.empty
                        , ccEvaluateTx =
                            const (pure Map.empty)
                        }
            result <- runFromIntentEither ctx some
            case result of
                Left err -> do
                    buildErrorCode err `shouldBe` "missing-utxos"
                    renderBuildError err
                        `shouldSatisfy` T.isInfixOf "tx-build: swap failed"
                    T.unpack (renderBuildError err)
                        `shouldSatisfy` (not . isInfixOf "runSwap")
                Right{} ->
                    expectationFailure "expected typed swap error"

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
            B16.encode (BSL.toStrict (brCborBytes result))
                `shouldBe` expected
            brFinalTxBody result `seq` pure ()

fixtureRewardAccount :: AccountAddress
fixtureRewardAccount =
    expectRight $
        parseRewardAccountForNetwork
            "mainnet"
            "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

rewardProvider :: Map.Map AccountAddress Coin -> Provider IO
rewardProvider rewardAccounts =
    provider
  where
    provider =
        Provider
            { withAcquired = singleShotWithAcquired provider
            , queryUTxOs = \_ -> pure []
            , queryUTxOByTxIn = \_ -> pure Map.empty
            , queryProtocolParams = fail "unused queryProtocolParams"
            , queryLedgerSnapshot = fail "unused queryLedgerSnapshot"
            , queryStakeRewards = \_ -> fail "unused queryStakeRewards"
            , queryRewardAccounts =
                pure . Map.restrictKeys rewardAccounts
            , queryVoteDelegatees = \_ ->
                fail "unused queryVoteDelegatees"
            , queryTreasury = fail "unused queryTreasury"
            , queryGovernanceState =
                fail "unused queryGovernanceState"
            , evaluateTx = \_ -> fail "unused evaluateTx"
            , posixMsToSlot = \_ -> fail "unused posixMsToSlot"
            , posixMsCeilSlot = \_ -> fail "unused posixMsCeilSlot"
            , queryUpperBoundSlot = \_ ->
                fail "unused queryUpperBoundSlot"
            }

missingWithdrawUtxos :: SomeException -> Bool
missingWithdrawUtxos =
    isInfixOf "tx-build: withdraw failed while gathering inputs"
        . displayException

txBodyOutputLovelace :: TxBody era ConwayEra -> Integer
txBodyOutputLovelace body =
    sum (txOutLovelace <$> toList (body ^. outputsTxBodyL))

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOut ^. valueTxOutL
    in  lovelace

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
        Success parsed -> Right parsed
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseCli :: [String] -> Either String (GlobalOpts, Cmd)
parseCli args =
    case execParserPure defaultPrefs opts args of
        Success parsed -> Right parsed
        Failure failure ->
            let (msg, _) = renderFailure failure "amaru-treasury-tx"
            in  Left msg
        CompletionInvoked{} -> Left "completion invoked"
