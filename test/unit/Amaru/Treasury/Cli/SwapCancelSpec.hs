{- |
Module      : Amaru.Treasury.Cli.SwapCancelSpec
Description : Parser tests for the swap-cancel command
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapCancelSpec (spec) where

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

import Amaru.Treasury.Cli.SwapCancel
    ( SwapCancelOpts (..)
    , resolveOrderScriptRefText
    , swapCancelOptsP
    )
import Amaru.Treasury.Constants
    ( sundaeOrderScriptRefMainnet
    )
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec = describe "Amaru.Treasury.Cli.SwapCancel" $ do
    it "parses the explicit-order cancel surface" $
        parseSwapCancelOpts
            [ "--metadata"
            , "metadata-mainnet.json"
            , "--scope"
            , "network_compliance"
            , "--wallet-txin"
            , txIn1
            , "--order-txin"
            , txIn2
            , "--order-script-ref"
            , txIn3
            , "--cancel-signer"
            , "network_compliance"
            , "--cancel-signer"
            , "ops_and_use_cases"
            , "--validity-hours"
            , "28"
            , "--out"
            , "cancel.cbor.hex"
            , "--report"
            , "cancel.report.json"
            , "--log"
            , "cancel.log"
            ]
            `shouldBe` Right
                SwapCancelOpts
                    { scoMetadataPath = "metadata-mainnet.json"
                    , scoScope = NetworkCompliance
                    , scoWalletTxIn = T.pack txIn1
                    , scoOrderTxIn = T.pack txIn2
                    , scoOrderScriptRef = Just (T.pack txIn3)
                    , scoCancelSigners =
                        T.pack
                            <$> [ "network_compliance"
                                , "ops_and_use_cases"
                                ]
                    , scoValidityHours = Just 28
                    , scoOutPath = Just "cancel.cbor.hex"
                    , scoReportPath = Just "cancel.report.json"
                    , scoLog = Just "cancel.log"
                    }

    it "accepts stdout CBOR with no optional report" $
        parseSwapCancelOpts
            [ "--metadata"
            , "metadata-mainnet.json"
            , "--scope"
            , "middleware"
            , "--wallet-txin"
            , txIn1
            , "--order-txin"
            , txIn2
            , "--order-script-ref"
            , txIn3
            ]
            `shouldBe` Right
                SwapCancelOpts
                    { scoMetadataPath = "metadata-mainnet.json"
                    , scoScope = Middleware
                    , scoWalletTxIn = T.pack txIn1
                    , scoOrderTxIn = T.pack txIn2
                    , scoOrderScriptRef = Just (T.pack txIn3)
                    , scoCancelSigners = []
                    , scoValidityHours = Nothing
                    , scoOutPath = Nothing
                    , scoReportPath = Nothing
                    , scoLog = Nothing
                    }

    it "parses omitted order script ref for the mainnet default path" $
        parseSwapCancelOpts
            [ "--metadata"
            , "metadata-mainnet.json"
            , "--scope"
            , "middleware"
            , "--wallet-txin"
            , txIn1
            , "--order-txin"
            , txIn2
            ]
            `shouldBe` Right
                SwapCancelOpts
                    { scoMetadataPath = "metadata-mainnet.json"
                    , scoScope = Middleware
                    , scoWalletTxIn = T.pack txIn1
                    , scoOrderTxIn = T.pack txIn2
                    , scoOrderScriptRef = Nothing
                    , scoCancelSigners = []
                    , scoValidityHours = Nothing
                    , scoOutPath = Nothing
                    , scoReportPath = Nothing
                    , scoLog = Nothing
                    }

    it "defaults omitted order script ref on mainnet" $
        resolveOrderScriptRefText "mainnet" Nothing
            `shouldBe` Right sundaeOrderScriptRefMainnet

    it "keeps explicit order script ref overrides" $
        resolveOrderScriptRefText "mainnet" (Just (T.pack txIn3))
            `shouldBe` Right (T.pack txIn3)

    it "requires explicit order script ref outside mainnet" $
        resolveOrderScriptRefText "preprod" Nothing
            `shouldBe` Left
                "--order-script-ref is required outside mainnet"

parseSwapCancelOpts :: [String] -> Either String SwapCancelOpts
parseSwapCancelOpts args =
    case execParserPure defaultPrefs (info swapCancelOptsP mempty) args of
        Success opts -> Right opts
        Failure _ -> Left "parse failure"
        CompletionInvoked _ -> Left "completion invoked"

txIn1 :: String
txIn1 =
    "0000000000000000000000000000000000000000000000000000000000000001#0"

txIn2 :: String
txIn2 =
    "0000000000000000000000000000000000000000000000000000000000000002#1"

txIn3 :: String
txIn3 =
    "0000000000000000000000000000000000000000000000000000000000000003#2"
