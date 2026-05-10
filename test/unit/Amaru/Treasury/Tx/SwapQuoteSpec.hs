{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuoteSpec
Description : Unit test scaffold for quote-derived swap parameters
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.SwapQuoteSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Ratio ((%))
import Data.Text qualified as T
import Network.HTTP.Client (requestHeaders)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts (..)
    , SwapQuotePaths (..)
    , SwapQuotePlan (..)
    , SwapQuoteQuoteArg (..)
    , SwapQuoteRunDecision (..)
    , decideSwapQuoteRun
    , deriveSwapQuotePlan
    , swapQuoteOptsP
    , swapQuotePaths
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.SwapQuote
    ( AffordabilityFailure (..)
    , AffordabilitySummary (..)
    , DerivedSwapParameters (..)
    , QuoteInput (..)
    , QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    , SlippageBps (..)
    , SwapQuoteAudit (..)
    , SwapQuoteError (..)
    , SwapQuoteOutputs (..)
    , SwapQuoteRequest (..)
    , SwapQuoteRequestChunk (..)
    , SwapQuoteStatus (..)
    , checkAffordability
    , deriveSwapParameters
    , parseQuoteInput
    , parseSlippageBps
    , renderAffordabilityFailure
    )
import Amaru.Treasury.Tx.SwapQuote.Source
    ( QuoteSource (..)
    , QuoteSourceError (..)
    , coinGeckoRequest
    , parseCoinGeckoAdaUsdResponse
    , parseQuoteSourceName
    , quoteSourceName
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RationaleAnswers (..)
    , SwapWizardQ (..)
    )

spec :: Spec
spec = describe "SwapQuote" $ do
    describe "deriveSwapParameters" $ do
        it "derives a six-decimal minimum rate from quote and slippage" $ do
            let observation =
                    QuoteObservation
                        { qoPair = AdaUsd
                        , qoQuote = 8123 % 10_000
                        , qoProvenance = OperatorOverride
                        }
                slippage = SlippageBps 100
                derived =
                    deriveSwapParameters
                        observation
                        slippage
                        SwapQuoteRequest
                            { sqrRequestedUsdm = 100_000
                            , sqrChunk = SplitInto 4
                            }
            derived
                `shouldSatisfy` isRight
            withDerived derived $ \parameters -> do
                dspRateNumerator parameters `shouldBe` 804_177
                dspRateDenominator parameters `shouldBe` 1_000_000

        it "ceilings requested ADA values from the emitted minimum rate" $ do
            let observation =
                    QuoteObservation
                        { qoPair = AdaUsd
                        , qoQuote = 1 % 3
                        , qoProvenance = OperatorOverride
                        }
                slippage = SlippageBps 0
                derived =
                    deriveSwapParameters
                        observation
                        slippage
                        SwapQuoteRequest
                            { sqrRequestedUsdm = 1
                            , sqrChunk = ChunkUsdm (1 % 3)
                            }
            derived
                `shouldSatisfy` isRight
            withDerived derived $ \parameters -> do
                dspRateNumerator parameters `shouldBe` 333_333
                dspRateDenominator parameters `shouldBe` 1_000_000
                dspAmountLovelace parameters `shouldBe` 3_000_004
                dspChunkSizeLovelace parameters `shouldBe` 1_000_002

        it "rejects tiny positive quotes with a zero floored rate numerator" $ do
            let observation =
                    QuoteObservation
                        { qoPair = AdaUsd
                        , qoQuote = 1 % 10_000_000
                        , qoProvenance = OperatorOverride
                        }
                derived =
                    deriveSwapParameters
                        observation
                        (SlippageBps 0)
                        SwapQuoteRequest
                            { sqrRequestedUsdm = 1
                            , sqrChunk = SplitInto 1
                            }
            derived `shouldBe` Left ZeroMinimumRate

    describe "checkAffordability" $ do
        it "accepts an exact affordability match" $ do
            checkAffordability
                sampleDerivedParameters
                3_280_000
                503_280_000
                `shouldBe` Right
                    AffordabilitySummary
                        { asDerived = sampleDerivedParameters
                        , asChunkCount = 1
                        , asExtraPerChunkLovelace = 3_280_000
                        , asRequiredLovelace = 503_280_000
                        , asAvailableLovelace = 503_280_000
                        , asShortfallLovelace = 0
                        }

        it "rejects an affordability check that is one lovelace short" $ do
            checkAffordability
                sampleDerivedParameters
                3_280_000
                503_279_999
                `shouldBe` Left
                    ( Unaffordable
                        AffordabilitySummary
                            { asDerived = sampleDerivedParameters
                            , asChunkCount = 1
                            , asExtraPerChunkLovelace = 3_280_000
                            , asRequiredLovelace = 503_280_000
                            , asAvailableLovelace = 503_279_999
                            , asShortfallLovelace = 1
                            }
                    )

        it "uses the generated chunk count for required lovelace" $ do
            let derived =
                    sampleDerivedParameters
                        { dspAmountLovelace = 500_000_001
                        , dspChunkSizeLovelace = 125_000_001
                        }
            checkAffordability derived 3_280_000 513_120_001
                `shouldBe` Right
                    AffordabilitySummary
                        { asDerived = derived
                        , asChunkCount = 4
                        , asExtraPerChunkLovelace = 3_280_000
                        , asRequiredLovelace = 513_120_001
                        , asAvailableLovelace = 513_120_001
                        , asShortfallLovelace = 0
                        }

        it
            "renders required, available, quote, slippage, and shortfall diagnostics"
            $ do
                case checkAffordability
                    sampleDerivedParameters
                    3_280_000
                    503_279_999 of
                    Left failure -> do
                        let rendered =
                                T.unpack (renderAffordabilityFailure failure)
                        rendered
                            `shouldContain` "required=503.280000 ADA (503280000 lovelace)"
                        rendered
                            `shouldContain` "available=503.279999 ADA (503279999 lovelace)"
                        rendered `shouldContain` "quote=0.8123 ADA/USD"
                        rendered `shouldContain` "slippage=100 bps"
                        rendered
                            `shouldContain` "shortfall=0.000001 ADA (1 lovelace)"
                    Right summary ->
                        expectationFailure
                            ("unexpected affordability success: " <> show summary)

    describe "parseSlippageBps" $ do
        it "rejects missing and invalid slippage before derivation" $ do
            parseSlippageBps Nothing `shouldSatisfy` isLeft
            parseSlippageBps (Just "-1") `shouldSatisfy` isLeft
            parseSlippageBps (Just "10000") `shouldSatisfy` isLeft

    describe "parseQuoteInput" $ do
        it "rejects invalid, zero, and negative quote overrides" $ do
            parseQuoteInput (AdaUsdOverride "current")
                `shouldSatisfy` isLeft
            parseQuoteInput (AdaUsdOverride "0")
                `shouldSatisfy` isLeft
            parseQuoteInput (AdaUsdOverride "-0.1")
                `shouldSatisfy` isLeft

        it "preserves explicit ADA/USD and ADA/USDM override observations" $ do
            parseQuoteInput (AdaUsdOverride "0.8123")
                `shouldBe` Right
                    QuoteObservation
                        { qoPair = AdaUsd
                        , qoQuote = 8123 % 10_000
                        , qoProvenance = OperatorOverride
                        }
            parseQuoteInput (AdaUsdmOverride "0.804177")
                `shouldBe` Right
                    QuoteObservation
                        { qoPair = AdaUsdm
                        , qoQuote = 804_177 % 1_000_000
                        , qoProvenance = OperatorOverride
                        }

    describe "source provider parsing" $ do
        it "parses a captured coingecko-ada-usd response with provenance" $ do
            bytes <-
                readFileStrict "test/fixtures/swap-quote/source.coingecko.json"
            parseCoinGeckoAdaUsdResponse "2026-05-09T10:00:00Z" bytes
                `shouldBe` Right
                    QuoteObservation
                        { qoPair = AdaUsd
                        , qoQuote = 8123 % 10_000
                        , qoProvenance =
                            QuoteSourceProvenance
                                { qspName = "coingecko-ada-usd"
                                , qspFetchedAt = "2026-05-09T10:00:00Z"
                                , qspRaw = "{\"cardano\":{\"usd\":0.8123}}\n"
                                }
                        }

        it "recognises coingecko-ada-usd as the named ADA/USD source" $
            quoteSourceName CoinGeckoAdaUsd `shouldBe` "coingecko-ada-usd"

        it "sends CoinGecko a descriptive User-Agent" $ do
            request <- coinGeckoRequest
            lookup "User-Agent" (requestHeaders request)
                `shouldBe` Just
                    "amaru-treasury-tx/0.2.1.1 (https://github.com/lambdasistemi/amaru-treasury-tx)"

    describe "swap-quote CLI parser" $ do
        it "accepts an explicit ADA/USD override quote input" $
            parseSwapQuote (baseSwapQuoteArgs <> ["--ada-usd", "0.8123"])
                `shouldBe` Right
                    ( sampleSwapQuoteOpts
                        ( SwapQuoteOverride
                            QuoteObservation
                                { qoPair = AdaUsd
                                , qoQuote = 8123 % 10_000
                                , qoProvenance = OperatorOverride
                                }
                        )
                    )

        it "accepts an explicit ADA/USDM override quote input" $
            parseSwapQuote (baseSwapQuoteArgs <> ["--ada-usdm", "0.804177"])
                `shouldBe` Right
                    ( sampleSwapQuoteOpts
                        ( SwapQuoteOverride
                            QuoteObservation
                                { qoPair = AdaUsdm
                                , qoQuote = 804_177 % 1_000_000
                                , qoProvenance = OperatorOverride
                                }
                        )
                    )

        it "accepts coingecko-ada-usd as the only named source" $
            parseSwapQuote
                (baseSwapQuoteArgs <> ["--price-source", "coingecko-ada-usd"])
                `shouldBe` Right
                    (sampleSwapQuoteOpts (SwapQuoteSource CoinGeckoAdaUsd))

        it "requires exactly one quote input" $ do
            parseSwapQuote baseSwapQuoteArgs `shouldSatisfy` isLeft
            parseSwapQuote
                ( baseSwapQuoteArgs
                    <> ["--ada-usd", "0.8123", "--ada-usdm", "0.804177"]
                )
                `shouldSatisfy` isLeft

        it "rejects named ADA/USDM live sources with a future-work error" $
            parseQuoteSourceName "coingecko-ada-usdm"
                `shouldBe` Left
                    (NamedAdaUsdmSourceUnavailable "coingecko-ada-usdm")

    describe "swap-quote runner planning" $ do
        it "derives the same SwapWizardQ values as the manual min-rate path" $ do
            plan <-
                expectRight
                    ( deriveSwapQuotePlan
                        "mainnet"
                        (sampleSwapQuoteOpts sampleAdaUsdOverride)
                        sampleAdaUsdObservation
                    )
            sqpAnswers plan
                `shouldBe` SwapWizardQ
                    { wqScope = NetworkCompliance
                    , wqAmountLovelace = 124_350_733_732
                    , wqChunkSizeLovelace = 3_768_204_052
                    , wqRateNumerator = 804_177
                    , wqRateDenominator = 1_000_000
                    , wqValidityHours = 28
                    , wqRationale =
                        RationaleAnswers
                            { raDescription = "Treasury swap"
                            , raJustification = "Quote-derived execution"
                            , raDestinationLabel = "USDM reserve"
                            , raEvent = Nothing
                            , raLabel = Nothing
                            }
                    , wqExtraSigners = []
                    }

        it "keeps affordability failures before unsigned CBOR output" $ do
            plan <-
                expectRight
                    ( deriveSwapQuotePlan
                        "mainnet"
                        (sampleSwapQuoteOpts sampleAdaUsdOverride)
                        sampleAdaUsdObservation
                    )
            case decideSwapQuoteRun plan 3_280_000 124_462_253_731 of
                SwapQuoteRunBlocked failure audit -> do
                    failure
                        `shouldBe` Unaffordable
                            AffordabilitySummary
                                { asDerived = sqpDerived plan
                                , asChunkCount = 34
                                , asExtraPerChunkLovelace = 3_280_000
                                , asRequiredLovelace = 124_462_253_732
                                , asAvailableLovelace = 124_462_253_731
                                , asShortfallLovelace = 1
                                }
                    sqaStatus audit `shouldBe` SwapQuoteAffordabilityFailed
                    sqoUnsignedCborHex (sqaOutputs audit) `shouldBe` Nothing
                SwapQuoteRunAllowed{} ->
                    expectationFailure "expected affordability failure"

        it "reports the standard swap-quote output paths" $
            swapQuotePaths "swap-run"
                `shouldBe` SwapQuotePaths
                    { sqpIntentJson = "swap-run/intent.json"
                    , sqpUnsignedCborHex = "swap-run/swap.cbor.hex"
                    , sqpParamsJson = "swap-run/params.json"
                    , sqpWizardLog = "swap-run/wizard.log"
                    , sqpBuildLog = "swap-run/build.log"
                    }

withDerived
    :: Either SwapQuoteError DerivedSwapParameters
    -> (DerivedSwapParameters -> Expectation)
    -> Expectation
withDerived derived assertion =
    case derived of
        Right parameters ->
            assertion parameters
        Left err ->
            expectationFailure
                ("unexpected derivation error: " <> show err)

sampleDerivedParameters :: DerivedSwapParameters
sampleDerivedParameters =
    DerivedSwapParameters
        { dspQuote =
            QuoteObservation
                { qoPair = AdaUsd
                , qoQuote = 8123 % 10_000
                , qoProvenance = OperatorOverride
                }
        , dspSlippageBps = SlippageBps 100
        , dspRateNumerator = 804_177
        , dspRateDenominator = 1_000_000
        , dspAmountLovelace = 500_000_000
        , dspChunkSizeLovelace = 500_000_000
        }

readFileStrict :: FilePath -> IO T.Text
readFileStrict path =
    T.pack <$> readFile path

parseSwapQuote :: [String] -> Either String SwapQuoteOpts
parseSwapQuote args =
    case execParserPure defaultPrefs (info swapQuoteOptsP mempty) args of
        Success opts -> Right opts
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

baseSwapQuoteArgs :: [String]
baseSwapQuoteArgs =
    [ "--wallet-addr"
    , "addr1test"
    , "--metadata"
    , "metadata.json"
    , "--scope"
    , "network_compliance"
    , "--usdm"
    , "100000"
    , "--split"
    , "33"
    , "--slippage-bps"
    , "100"
    , "--validity-hours"
    , "28"
    , "--description"
    , "Treasury swap"
    , "--justification"
    , "Quote-derived execution"
    , "--destination-label"
    , "USDM reserve"
    , "--out-dir"
    , "swap-run"
    ]

sampleSwapQuoteOpts :: SwapQuoteQuoteArg -> SwapQuoteOpts
sampleSwapQuoteOpts quote =
    SwapQuoteOpts
        { sqoWalletAddr = "addr1test"
        , sqoMetadataPath = "metadata.json"
        , sqoOutDir = "swap-run"
        , sqoScope = NetworkCompliance
        , sqoRequestedUsdm = "100000"
        , sqoChunk = SplitInto 33
        , sqoQuote = quote
        , sqoSlippageBps = SlippageBps 100
        , sqoValidityHours = 28
        , sqoDescription = "Treasury swap"
        , sqoJustification = "Quote-derived execution"
        , sqoDestinationLabel = "USDM reserve"
        , sqoEvent = Nothing
        , sqoLabel = Nothing
        , sqoSigners = []
        }

sampleAdaUsdOverride :: SwapQuoteQuoteArg
sampleAdaUsdOverride =
    SwapQuoteOverride sampleAdaUsdObservation

sampleAdaUsdObservation :: QuoteObservation
sampleAdaUsdObservation =
    QuoteObservation
        { qoPair = AdaUsd
        , qoQuote = 8123 % 10_000
        , qoProvenance = OperatorOverride
        }

expectRight :: (Show e) => Either e a -> IO a
expectRight = \case
    Right value ->
        pure value
    Left err ->
        expectationFailure ("unexpected Left: " <> show err)
            >> fail "unexpected Left"
