{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuoteSpec
Description : Unit test scaffold for quote-derived swap parameters
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.SwapQuoteSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Ratio ((%))
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.SwapQuote
    ( DerivedSwapParameters (..)
    , QuoteInput (..)
    , QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    , SlippageBps (..)
    , SwapQuoteError (..)
    , SwapQuoteRequest (..)
    , SwapQuoteRequestChunk (..)
    , deriveSwapParameters
    , parseQuoteInput
    , parseSlippageBps
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
