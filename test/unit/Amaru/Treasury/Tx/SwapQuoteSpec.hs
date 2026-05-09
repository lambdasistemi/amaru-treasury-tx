{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuoteSpec
Description : Unit test scaffold for quote-derived swap parameters
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.SwapQuoteSpec (spec) where

import Data.Either (isLeft)
import Data.Ratio ((%))
import Test.Hspec
    ( Spec
    , describe
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
            dspRateNumerator derived `shouldBe` 804_177
            dspRateDenominator derived `shouldBe` 1_000_000

        it "floors rate numerator and ceilings requested ADA values" $ do
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
            dspRateNumerator derived `shouldBe` 333_333
            dspRateDenominator derived `shouldBe` 1_000_000
            dspAmountLovelace derived `shouldBe` 3_000_000
            dspChunkSizeLovelace derived `shouldBe` 1_000_000

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
