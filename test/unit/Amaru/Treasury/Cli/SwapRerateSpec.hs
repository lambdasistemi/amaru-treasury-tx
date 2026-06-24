{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Cli.SwapRerateSpec
Description : Parser and branch tests for the swap-rerate command
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapRerateSpec (spec) where

import Control.Exception
    ( try
    )
import Control.Monad
    ( when
    )
import Data.Aeson
    ( Value
    , eitherDecodeFileStrict'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Functor
    ( ($>)
    )
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    )
import Ouroboros.Network.Magic
    ( NetworkMagic (..)
    )
import System.Directory
    ( doesFileExist
    )
import System.Exit
    ( ExitCode (..)
    )
import System.FilePath
    ( (</>)
    )
import System.IO.Temp
    ( withSystemTempDirectory
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldReturn
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , parseCliArgs
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateDecision (..)
    , SwapRerateFunding (..)
    , SwapRerateOpts (..)
    , SwapRerateOrderCandidate (..)
    , SwapReratePassthroughReason (..)
    , SwapRerateSelectionMode (..)
    , decideSwapRerateBranch
    , runSwapRerate
    , swapRerateFunding
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    )
import Amaru.Treasury.Swap.Rerate.Types
    ( RerateBudgetEstimate (..)
    , ReratePlan (..)
    , ReratePlanReason (..)
    , RerateSplit (..)
    )

spec :: Spec
spec = describe "Amaru.Treasury.Cli.SwapRerate" $ do
    it "builds offline single-tx CBOR and report artifacts" $
        withSystemTempDirectory "swap-rerate-single" $ \dir -> do
            let out = dir </> "rerate.cbor.hex"
                report = dir </> "rerate.report.json"
            runSwapRerate
                mainnetOpts
                ( offlineOpts (SwapRerateSelectExplicit [syntheticOrderTxIn])
                )
                    { sroOutPath = Just out
                    , sroReportPath = Just report
                    }
            cborHex <- BS.readFile out
            cborHex `shouldSatisfyNot` BS.null
            rendered <- readJsonReport report
            rendered `shouldContain` T.unpack syntheticOrderTxIn
            rendered `shouldContain` "\"status\":\"single_tx\""
            rendered `shouldContain` "\"newRate\":0.3"
            rendered `shouldContain` "returned"
            rendered `shouldContain` "reOffered"
            rendered `shouldContain` "witness"

    it "writes an over-budget split report instead of CBOR" $
        withSystemTempDirectory "swap-rerate-split" $ \dir -> do
            let out = dir </> "rerate.cbor.hex"
                report = dir </> "rerate.report.json"
            runSwapRerate
                mainnetOpts
                ( offlineOpts (SwapRerateSelectExplicit manyOrderTxIns)
                )
                    { sroOutPath = Just out
                    , sroReportPath = Just report
                    }
            doesFileExist out `shouldReturn` False
            rendered <- readJsonReport report
            rendered `shouldContain` "\"status\":\"split\""
            rendered `shouldContain` "\"reason\":\"RerateOverExecutionMemory\""
            rendered `shouldContain` T.unpack firstManyOrderTxIn
            rendered `shouldContain` "\"groups\""

    it "rejects wrong-scope offline orders before writing CBOR" $
        withSystemTempDirectory "swap-rerate-wrong-scope" $ \dir -> do
            let out = dir </> "rerate.cbor.hex"
                report = dir </> "rerate.report.json"
            result <-
                try @ExitCode $
                    runSwapRerate
                        mainnetOpts
                        ( ( offlineOpts
                                ( SwapRerateSelectExplicit
                                    [syntheticOrderTxIn]
                                )
                          )
                            { sroScope = Middleware
                            , sroOutPath = Just out
                            , sroReportPath = Just report
                            }
                        )
            result `shouldBe` Left (ExitFailure 1)
            doesFileExist out `shouldReturn` False
            rendered <- readJsonReport report
            rendered `shouldContain` "\"status\":\"rejected\""
            rendered `shouldContain` "wrong_scope"
            rendered `shouldContain` T.unpack syntheticOrderTxIn

    it "reports decline-retract passthrough without building" $
        withSystemTempDirectory "swap-rerate-decline" $ \dir -> do
            let out = dir </> "rerate.cbor.hex"
                report = dir </> "rerate.report.json"
            runSwapRerate
                mainnetOpts
                (offlineOpts SwapRerateDeclineRetract)
                    { sroOutPath = Just out
                    , sroReportPath = Just report
                    }
            doesFileExist out `shouldReturn` False
            rendered <- readJsonReport report
            rendered `shouldContain` "\"status\":\"passthrough\""
            rendered `shouldContain` "declined"
            rendered `shouldContain` "plain swap"

    it "reports no-orders passthrough without building" $
        withSystemTempDirectory "swap-rerate-no-orders" $ \dir -> do
            let out = dir </> "rerate.cbor.hex"
                report = dir </> "rerate.report.json"
            runSwapRerate
                mainnetOpts
                (offlineOpts SwapRerateSelectAll)
                    { sroScope = CoreDevelopment
                    , sroOutPath = Just out
                    , sroReportPath = Just report
                    }
            doesFileExist out `shouldReturn` False
            rendered <- readJsonReport report
            rendered `shouldContain` "\"status\":\"passthrough\""
            rendered `shouldContain` "no pending orders"
            rendered `shouldContain` "plain swap"

    it "gathers the full live node-socket re-rate context" $ do
        src <- readFile "lib/Amaru/Treasury/Cli/SwapRerate.hs"
        src `shouldSatisfyNot` contains "slice 3"
        src `shouldSatisfyNot` contains "live --node-socket discovery"
        src `shouldContain` "withLocalNodeBackend"
        src `shouldContain` "withLiveContext"
        src `shouldContain` "rpiOrderScriptRef"
        src `shouldContain` "rpiExtraWalletTxIns"
        src `shouldContain` "rpiScopesDeployedAt"
        src `shouldContain` "rpiPermissionsDeployedAt"
        src `shouldContain` "rpiTreasuryDeployedAt"
        src `shouldContain` "rpiRegistryDeployedAt"
        src `shouldContain` "selectWallet"
        src `shouldContain` "walletFeeSlackLovelace"
        src `shouldContain` "--wallet-address"

    it "parses the wallet-address swap-rerate operator contract" $
        case parseSwapRerateOpts walletAddressArgs of
            Right opts -> do
                opts
                    `shouldBe` SwapRerateOpts
                        { sroMetadataPath = "metadata-mainnet.json"
                        , sroScope = NetworkCompliance
                        , sroWalletTxIn = walletAddress
                        , sroCollateralTxIn = Nothing
                        , sroSelectionMode =
                            SwapRerateSelectExplicit
                                [orderTxIn1, orderTxIn2]
                        , sroNewRate = 0.245
                        , sroValidityHours = Just 28
                        , sroOutPath = Just "rerate.cbor.hex"
                        , sroReportPath = Just "rerate.report.json"
                        , sroLog = Just "rerate.log"
                        }
                swapRerateFunding opts
                    `shouldBe` SwapRerateWalletAddress walletAddress
            Left err -> expectationFailure err

    it "rejects legacy visible manual funding flags" $
        parseSwapRerateOpts legacyManualFundingArgs
            `shouldBe` Left "parse failure"

    it "keeps hidden fixture explicit funding parseable" $
        case parseSwapRerateOpts fixtureFundingArgs of
            Right opts -> do
                opts
                    `shouldBe` SwapRerateOpts
                        { sroMetadataPath = "metadata-mainnet.json"
                        , sroScope = NetworkCompliance
                        , sroWalletTxIn = walletTxIn
                        , sroCollateralTxIn = Just collateralTxIn
                        , sroSelectionMode =
                            SwapRerateSelectExplicit
                                [orderTxIn1, orderTxIn2]
                        , sroNewRate = 0.245
                        , sroValidityHours = Nothing
                        , sroOutPath = Nothing
                        , sroReportPath = Nothing
                        , sroLog = Nothing
                        }
                swapRerateFunding opts
                    `shouldBe` SwapRerateExplicitFunding
                        walletTxIn
                        (Just collateralTxIn)
            Left err -> expectationFailure err

    it "parses a single explicit selected order" $
        parseSwapRerateSelection
            (replaceOrderArgs [orderTxIn1] walletAddressArgs)
            `shouldBe` Right (SwapRerateSelectExplicit [orderTxIn1])

    it "parses explicit decline/no-retract mode" $
        parseSwapRerateSelection declineArgs
            `shouldBe` Right SwapRerateDeclineRetract

    it "reports a single-transaction branch decision" $
        decideSwapRerateBranch
            NetworkCompliance
            (SwapRerateSelectExplicit [orderTxIn1])
            [candidate orderTxIn1 NetworkCompliance]
            (Just (SingleTx RerateWithinBudget estimate [orderTxIn1]))
            `shouldBe` Right
                ( SwapRerateSingleTx
                    RerateWithinBudget
                    estimate
                    [orderTxIn1]
                )

    it "reports a split fallback branch decision" $
        let splits =
                [ RerateSplit
                    { rsOrders = [orderTxIn1]
                    , rsCreatesReplacement = False
                    }
                , RerateSplit
                    { rsOrders = [orderTxIn2]
                    , rsCreatesReplacement = True
                    }
                ]
        in  decideSwapRerateBranch
                NetworkCompliance
                (SwapRerateSelectExplicit [orderTxIn1, orderTxIn2])
                [ candidate orderTxIn1 NetworkCompliance
                , candidate orderTxIn2 NetworkCompliance
                ]
                (Just (Split RerateOverTxSize estimate splits))
                `shouldBe` Right
                    ( SwapRerateSplitPlan
                        RerateOverTxSize
                        estimate
                        splits
                    )

    it "reports passthrough when the operator declines retraction" $
        decideSwapRerateBranch
            NetworkCompliance
            SwapRerateDeclineRetract
            [candidate orderTxIn1 NetworkCompliance]
            Nothing
            `shouldBe` Right
                (SwapReratePassthrough SwapRerateRetractDeclined)

    it "reports passthrough when no pending order is present" $
        decideSwapRerateBranch
            NetworkCompliance
            SwapRerateSelectAll
            []
            Nothing
            `shouldBe` Right
                (SwapReratePassthrough SwapRerateNoPendingOrders)

    it "rejects wrong-scope selected orders at the CLI helper layer" $
        decideSwapRerateBranch
            NetworkCompliance
            (SwapRerateSelectExplicit [orderTxIn1])
            [candidate orderTxIn1 Middleware]
            (Just (SingleTx RerateWithinBudget estimate [orderTxIn1]))
            `shouldBe` Left
                ( "selected order "
                    <> orderTxIn1
                    <> " belongs to middleware; expected network_compliance"
                )

parseSwapRerateOpts :: [String] -> Either String SwapRerateOpts
parseSwapRerateOpts args =
    case parseCliArgs args of
        Success (_, CmdSwapRerate opts) -> Right opts
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseSwapRerateSelection
    :: [String] -> Either String SwapRerateSelectionMode
parseSwapRerateSelection args =
    sroSelectionMode <$> parseSwapRerateOpts args

replaceOrderArgs :: [Text] -> [String] -> [String]
replaceOrderArgs orders args =
    baseArgs
        <> concatMap
            (\txIn -> ["--order-txin", T.unpack txIn])
            orders
        <> tailArgs
  where
    (baseArgs, afterMode) =
        break (== "--order-txin") args
    tailArgs =
        dropWhileOrderArgs afterMode

dropWhileOrderArgs :: [String] -> [String]
dropWhileOrderArgs ("--order-txin" : _ : rest) =
    dropWhileOrderArgs rest
dropWhileOrderArgs rest = rest

candidate :: Text -> ScopeId -> SwapRerateOrderCandidate
candidate txIn scope =
    SwapRerateOrderCandidate
        { srocTxIn = txIn
        , srocScope = scope
        }

estimate :: RerateBudgetEstimate
estimate =
    RerateBudgetEstimate
        { rbeMemory = 10
        , rbeSteps = 20
        , rbeSize = 30
        }

walletAddressArgs :: [String]
walletAddressArgs =
    [ "swap-rerate"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--wallet-address"
    , T.unpack walletAddress
    , "--order-txin"
    , T.unpack orderTxIn1
    , "--order-txin"
    , T.unpack orderTxIn2
    , "--new-rate"
    , "0.245"
    , "--validity-hours"
    , "28"
    , "--out"
    , "rerate.cbor.hex"
    , "--report"
    , "rerate.report.json"
    , "--log"
    , "rerate.log"
    ]

legacyManualFundingArgs :: [String]
legacyManualFundingArgs =
    [ "swap-rerate"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--wallet-txin"
    , T.unpack walletTxIn
    , "--collateral-txin"
    , T.unpack collateralTxIn
    , "--order-txin"
    , T.unpack orderTxIn1
    , "--new-rate"
    , "0.245"
    ]

fixtureFundingArgs :: [String]
fixtureFundingArgs =
    [ "swap-rerate"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--fixture-wallet-txin"
    , T.unpack walletTxIn
    , "--fixture-collateral-txin"
    , T.unpack collateralTxIn
    , "--order-txin"
    , T.unpack orderTxIn1
    , "--order-txin"
    , T.unpack orderTxIn2
    , "--new-rate"
    , "0.245"
    ]

declineArgs :: [String]
declineArgs =
    [ "swap-rerate"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--wallet-address"
    , T.unpack walletAddress
    , "--no-retract"
    , "--new-rate"
    , "0.245"
    ]

mainnetOpts :: GlobalOpts
mainnetOpts =
    GlobalOpts
        { goSocketPath = Nothing
        , goNetworkMagic = NetworkMagic 764_824_073
        , goNetworkName = Just "mainnet"
        }

offlineOpts :: SwapRerateSelectionMode -> SwapRerateOpts
offlineOpts mode =
    SwapRerateOpts
        { sroMetadataPath = "test/fixtures/metadata.json"
        , sroScope = NetworkCompliance
        , sroWalletTxIn =
            "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
        , sroCollateralTxIn = Nothing
        , sroSelectionMode = mode
        , sroNewRate = 0.3
        , sroValidityHours = Nothing
        , sroOutPath = Nothing
        , sroReportPath = Nothing
        , sroLog = Nothing
        }

readJsonReport :: FilePath -> IO String
readJsonReport path = do
    decoded <- eitherDecodeFileStrict' @Value path
    case decoded of
        Left err ->
            expectationFailure ("report JSON did not parse: " <> err)
                $> ""
        Right{} -> BSC.unpack <$> BS.readFile path

shouldSatisfyNot :: (Show a) => a -> (a -> Bool) -> IO ()
shouldSatisfyNot value predicate =
    when (predicate value) $
        expectationFailure ("unexpected value: " <> show value)

contains :: String -> String -> Bool
contains needle haystack =
    needle `List.isInfixOf` haystack

walletTxIn :: Text
walletTxIn =
    "0000000000000000000000000000000000000000000000000000000000000001#0"

collateralTxIn :: Text
collateralTxIn =
    "0000000000000000000000000000000000000000000000000000000000000002#1"

walletAddress :: Text
walletAddress =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

orderTxIn1 :: Text
orderTxIn1 =
    "0000000000000000000000000000000000000000000000000000000000000003#2"

orderTxIn2 :: Text
orderTxIn2 =
    "0000000000000000000000000000000000000000000000000000000000000004#3"

syntheticOrderTxIn :: Text
syntheticOrderTxIn =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0"

manyOrderTxIns :: [Text]
manyOrderTxIns =
    [ T.justifyRight 64 '0' (T.pack (show n)) <> "#0"
    | n <- [100 .. 140 :: Int]
    ]

firstManyOrderTxIn :: Text
firstManyOrderTxIn =
    "0000000000000000000000000000000000000000000000000000000000000100#0"
