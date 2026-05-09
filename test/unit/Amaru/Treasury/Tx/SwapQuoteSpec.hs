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

import Amaru.Treasury.Tx.SwapQuote
    ( AffordabilityFailure (..)
    , AffordabilitySummary (..)
    , DerivedSwapParameters (..)
    , QuoteInput (..)
    , QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    , SlippageBps (..)
    , SwapQuoteError (..)
    , SwapQuoteRequest (..)
    , SwapQuoteRequestChunk (..)
    , checkAffordability
    , deriveSwapParameters
    , parseQuoteInput
    , parseSlippageBps
    , renderAffordabilityFailure
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
