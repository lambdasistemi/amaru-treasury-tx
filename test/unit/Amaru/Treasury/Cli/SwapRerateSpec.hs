{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.SwapRerateSpec
Description : Parser and branch tests for the swap-rerate command
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapRerateSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , parseCliArgs
    )
import Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateDecision (..)
    , SwapRerateOpts (..)
    , SwapRerateOrderCandidate (..)
    , SwapReratePassthroughReason (..)
    , SwapRerateSelectionMode (..)
    , decideSwapRerateBranch
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
    it "parses the explicit-order swap-rerate operator contract" $
        parseSwapRerateOpts explicitOrderArgs
            `shouldBe` Right
                SwapRerateOpts
                    { sroMetadataPath = "metadata-mainnet.json"
                    , sroScope = NetworkCompliance
                    , sroWalletTxIn = walletTxIn
                    , sroCollateralTxIn = Just collateralTxIn
                    , sroSelectionMode =
                        SwapRerateSelectExplicit [orderTxIn1, orderTxIn2]
                    , sroNewRate = 0.245
                    , sroValidityHours = Just 28
                    , sroOutPath = Just "rerate.cbor.hex"
                    , sroReportPath = Just "rerate.report.json"
                    , sroLog = Just "rerate.log"
                    }

    it "parses a single explicit selected order" $
        parseSwapRerateSelection
            (replaceOrderArgs [orderTxIn1] explicitOrderArgs)
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

explicitOrderArgs :: [String]
explicitOrderArgs =
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

declineArgs :: [String]
declineArgs =
    [ "swap-rerate"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--wallet-txin"
    , T.unpack walletTxIn
    , "--no-retract"
    , "--new-rate"
    , "0.245"
    ]

walletTxIn :: Text
walletTxIn =
    "0000000000000000000000000000000000000000000000000000000000000001#0"

collateralTxIn :: Text
collateralTxIn =
    "0000000000000000000000000000000000000000000000000000000000000002#1"

orderTxIn1 :: Text
orderTxIn1 =
    "0000000000000000000000000000000000000000000000000000000000000003#2"

orderTxIn2 :: Text
orderTxIn2 =
    "0000000000000000000000000000000000000000000000000000000000000004#3"
