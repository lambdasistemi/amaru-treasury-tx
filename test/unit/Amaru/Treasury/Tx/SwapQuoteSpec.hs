{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuoteSpec
Description : Unit test scaffold for quote-derived swap parameters
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.SwapQuoteSpec (spec) where

import Data.ByteString.Char8 qualified as BS
import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Ratio ((%))
import Data.Text qualified as T
import Data.Version (showVersion)
import Network.HTTP.Client (Request, requestHeaders)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Paths_amaru_treasury_tx qualified as P
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
    , ComponentObservation (..)
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
    ( QuoteProvider (..)
    , QuoteSource (..)
    , QuoteSourceError (..)
    , coinGeckoRequest
    , coinGeckoUsdmRequest
    , composeAdaUsdmFromComponents
    , fetchQuoteSource
    , parseCoinGeckoAdaUsdComponent
    , parseCoinGeckoUsdmUsdComponent
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
                        rendered `shouldContain` "quote=0.8123 ADA/USDM"
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
            parseQuoteInput (AdaUsdmOverride "current")
                `shouldSatisfy` isLeft
            parseQuoteInput (AdaUsdmOverride "0")
                `shouldSatisfy` isLeft
            parseQuoteInput (AdaUsdmOverride "-0.1")
                `shouldSatisfy` isLeft

        it "preserves explicit ADA/USDM override observations" $
            parseQuoteInput (AdaUsdmOverride "0.804177")
                `shouldBe` Right
                    QuoteObservation
                        { qoPair = AdaUsdm
                        , qoQuote = 804_177 % 1_000_000
                        , qoProvenance = OperatorOverride
                        }

    describe "source component parsing" $ do
        it "parses a captured coingecko ADA/USD response into a component" $ do
            bytes <-
                readFileStrict
                    "test/fixtures/swap-quote/source.coingecko-ada-usd.json"
            parseCoinGeckoAdaUsdComponent "2026-05-09T10:00:00Z" bytes
                `shouldBe` Right
                    ComponentObservation
                        { coName = "coingecko-ada-usd"
                        , coValue = 8123 % 10_000
                        , coFetchedAt = "2026-05-09T10:00:00Z"
                        , coRaw = "{\"cardano\":{\"usd\":0.8123}}\n"
                        }

        it "parses a captured coingecko USDM/USD response into a component" $ do
            bytes <-
                readFileStrict
                    "test/fixtures/swap-quote/source.coingecko-usdm-usd.json"
            parseCoinGeckoUsdmUsdComponent "2026-05-09T10:00:00Z" bytes
                `shouldBe` Right
                    ComponentObservation
                        { coName = "coingecko-usdm-usd"
                        , coValue = 996_629 % 1_000_000
                        , coFetchedAt = "2026-05-09T10:00:00Z"
                        , coRaw = "{\"usdm-2\":{\"usd\":0.996629}}\n"
                        }

        it "recognises coingecko-ada-usdm as the named ADA/USDM source" $
            quoteSourceName CoinGeckoAdaUsdm `shouldBe` "coingecko-ada-usdm"

        it
            "sends CoinGecko ADA/USD a descriptive User-Agent tracking the cabal version"
            $ do
                request <- coinGeckoRequest
                expectedAdvertisedUserAgent request

        it
            "sends CoinGecko USDM/USD a descriptive User-Agent tracking the cabal version"
            $ do
                request <- coinGeckoUsdmRequest
                expectedAdvertisedUserAgent request

    describe "derived coingecko-ada-usdm composition" $ do
        it
            "composes ADA/USDM as adaUsd / usdmUsd with both components captured"
            $ do
                let adaUsdComp =
                        ComponentObservation
                            { coName = "coingecko-ada-usd"
                            , coValue = 270_971 % 1_000_000
                            , coFetchedAt = "2026-05-14T09:59:58Z"
                            , coRaw = "{\"cardano\":{\"usd\":0.270971}}\n"
                            }
                    usdmUsdComp =
                        ComponentObservation
                            { coName = "coingecko-usdm-usd"
                            , coValue = 996_629 % 1_000_000
                            , coFetchedAt = "2026-05-14T09:59:59Z"
                            , coRaw = "{\"usdm-2\":{\"usd\":0.996629}}\n"
                            }
                    observation =
                        composeAdaUsdmFromComponents adaUsdComp usdmUsdComp
                qoPair observation `shouldBe` AdaUsdm
                qoQuote observation `shouldBe` 270_971 % 996_629
                qoProvenance observation
                    `shouldBe` DerivedQuoteProvenance
                        { dqpName = "coingecko-ada-usdm"
                        , dqpComponents = adaUsdComp :| [usdmUsdComp]
                        }

        it "fetches the derived observation through a stubbed QuoteProvider" $ do
            let adaUsdComp =
                    ComponentObservation
                        { coName = "coingecko-ada-usd"
                        , coValue = 270_971 % 1_000_000
                        , coFetchedAt = "2026-05-14T09:59:58Z"
                        , coRaw = "{\"cardano\":{\"usd\":0.270971}}\n"
                        }
                usdmUsdComp =
                    ComponentObservation
                        { coName = "coingecko-usdm-usd"
                        , coValue = 996_629 % 1_000_000
                        , coFetchedAt = "2026-05-14T09:59:59Z"
                        , coRaw = "{\"usdm-2\":{\"usd\":0.996629}}\n"
                        }
                stubProvider :: QuoteProvider IO
                stubProvider =
                    QuoteProvider $ \_source fetchedAt ->
                        pure
                            ( Right
                                ( composeAdaUsdmFromComponents
                                    adaUsdComp
                                    usdmUsdComp{coFetchedAt = fetchedAt}
                                )
                            )
            result <-
                fetchQuoteSource stubProvider CoinGeckoAdaUsdm "2026-05-14T10:00:00Z"
            case result of
                Right obs -> do
                    qoPair obs `shouldBe` AdaUsdm
                    qoQuote obs `shouldBe` 270_971 % 996_629
                Left err ->
                    expectationFailure ("unexpected provider error: " <> show err)

    describe "swap-quote CLI parser" $ do
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

        it "accepts coingecko-ada-usdm as the only named source" $
            parseSwapQuote
                (baseSwapQuoteArgs <> ["--price-source", "coingecko-ada-usdm"])
                `shouldBe` Right
                    (sampleSwapQuoteOpts (SwapQuoteSource CoinGeckoAdaUsdm))

        it "rejects the retired --ada-usd override" $
            parseSwapQuote (baseSwapQuoteArgs <> ["--ada-usd", "0.8123"])
                `shouldSatisfy` isLeft

        it "rejects coingecko-ada-usd with a retirement error" $
            parseQuoteSourceName "coingecko-ada-usd"
                `shouldSatisfy` \case
                    Left (RetiredQuoteSource name _) ->
                        name == "coingecko-ada-usd"
                    _ -> False

        it "requires exactly one quote input" $ do
            parseSwapQuote baseSwapQuoteArgs `shouldSatisfy` isLeft
            parseSwapQuote
                ( baseSwapQuoteArgs
                    <> ["--ada-usdm", "0.804177", "--price-source", "coingecko-ada-usdm"]
                )
                `shouldSatisfy` isLeft

    describe "swap-quote runner planning" $ do
        it "derives the same SwapWizardQ values as the manual min-rate path" $ do
            plan <-
                expectRight
                    ( deriveSwapQuotePlan
                        "mainnet"
                        (sampleSwapQuoteOpts sampleAdaUsdmOverride)
                        sampleAdaUsdmObservation
                    )
            sqpAnswers plan
                `shouldBe` SwapWizardQ
                    { wqScope = NetworkCompliance
                    , wqAmountLovelace = 124_350_733_732
                    , wqChunkSizeLovelace = 3_768_204_052
                    , wqRateNumerator = 804_177
                    , wqRateDenominator = 1_000_000
                    , wqValidityHours = Just 28
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
                        (sampleSwapQuoteOpts sampleAdaUsdmOverride)
                        sampleAdaUsdmObservation
                    )
            -- Under issue #91 the wizard distributes a small
            -- remainder across the chunks instead of emitting a
            -- dust output, so chunkCount drops by 1 here (34 → 33)
            -- and the required-funding total shrinks by one
            -- 'extraPerChunkLovelace'.
            case decideSwapQuoteRun plan 3_280_000 124_458_973_731 of
                SwapQuoteRunBlocked failure audit -> do
                    failure
                        `shouldBe` Unaffordable
                            AffordabilitySummary
                                { asDerived = sqpDerived plan
                                , asChunkCount = 33
                                , asExtraPerChunkLovelace = 3_280_000
                                , asRequiredLovelace = 124_458_973_732
                                , asAvailableLovelace = 124_458_973_731
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
                { qoPair = AdaUsdm
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

expectedAdvertisedUserAgent :: Request -> Expectation
expectedAdvertisedUserAgent request = do
    let expected =
            BS.pack $
                "amaru-treasury-tx/"
                    <> showVersion P.version
                    <> " (https://github.com/lambdasistemi/amaru-treasury-tx)"
    lookup "User-Agent" (requestHeaders request)
        `shouldBe` Just expected

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
        , sqoValidityHours = Just 28
        , sqoDescription = "Treasury swap"
        , sqoJustification = "Quote-derived execution"
        , sqoDestinationLabel = "USDM reserve"
        , sqoEvent = Nothing
        , sqoLabel = Nothing
        , sqoSigners = []
        }

sampleAdaUsdmOverride :: SwapQuoteQuoteArg
sampleAdaUsdmOverride =
    SwapQuoteOverride sampleAdaUsdmObservation

sampleAdaUsdmObservation :: QuoteObservation
sampleAdaUsdmObservation =
    QuoteObservation
        { qoPair = AdaUsdm
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
