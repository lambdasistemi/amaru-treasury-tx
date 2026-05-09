{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuote
Description : Pure quote-derived swap parameter calculation
License     : Apache-2.0

This module owns exact quote/slippage arithmetic before later slices
wire quote sources, affordability checks, audit JSON, or CLI execution.
-}
module Amaru.Treasury.Tx.SwapQuote
    ( QuotePair (..)
    , QuoteProvenance (..)
    , QuoteObservation (..)
    , SlippageBps (..)
    , QuoteInput (..)
    , SwapQuoteRequest (..)
    , SwapQuoteRequestChunk (..)
    , DerivedSwapParameters (..)
    , SwapQuoteError (..)
    , parseQuoteInput
    , parseSlippageBps
    , deriveSwapParameters
    ) where

import Data.Char (digitToInt, isDigit)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as T

data QuotePair
    = AdaUsd
    | AdaUsdm
    deriving (Eq, Show)

data QuoteProvenance
    = OperatorOverride
    deriving (Eq, Show)

data QuoteObservation = QuoteObservation
    { qoPair :: !QuotePair
    , qoQuote :: !Rational
    , qoProvenance :: !QuoteProvenance
    }
    deriving (Eq, Show)

newtype SlippageBps = SlippageBps
    { unSlippageBps :: Integer
    }
    deriving (Eq, Show)

data QuoteInput
    = AdaUsdOverride !Text
    | AdaUsdmOverride !Text
    deriving (Eq, Show)

data SwapQuoteRequest = SwapQuoteRequest
    { sqrRequestedUsdm :: !Rational
    , sqrChunk :: !SwapQuoteRequestChunk
    }
    deriving (Eq, Show)

data SwapQuoteRequestChunk
    = SplitInto !Int
    | ChunkUsdm !Rational
    deriving (Eq, Show)

data DerivedSwapParameters = DerivedSwapParameters
    { dspQuote :: !QuoteObservation
    , dspSlippageBps :: !SlippageBps
    , dspRateNumerator :: !Integer
    , dspRateDenominator :: !Integer
    , dspAmountLovelace :: !Integer
    , dspChunkSizeLovelace :: !Integer
    }
    deriving (Eq, Show)

data SwapQuoteError
    = MissingSlippage
    | InvalidSlippage !Text
    | InvalidQuote !Text
    | ZeroMinimumRate
    deriving (Eq, Show)

parseQuoteInput
    :: QuoteInput -> Either SwapQuoteError QuoteObservation
parseQuoteInput = \case
    AdaUsdOverride raw ->
        override AdaUsd raw
    AdaUsdmOverride raw ->
        override AdaUsdm raw
  where
    override pair raw = do
        quote <- parsePositiveDecimal raw
        pure
            QuoteObservation
                { qoPair = pair
                , qoQuote = quote
                , qoProvenance = OperatorOverride
                }

parseSlippageBps :: Maybe Text -> Either SwapQuoteError SlippageBps
parseSlippageBps Nothing = Left MissingSlippage
parseSlippageBps (Just raw)
    | T.null raw || not (T.all isDigit raw) =
        Left (InvalidSlippage raw)
    | bps < 0 || bps >= 10_000 =
        Left (InvalidSlippage raw)
    | otherwise =
        Right (SlippageBps bps)
  where
    bps = decimalDigitsToInteger raw

deriveSwapParameters
    :: QuoteObservation
    -> SlippageBps
    -> SwapQuoteRequest
    -> Either SwapQuoteError DerivedSwapParameters
deriveSwapParameters observation slippage request =
    if rateNumerator <= 0
        then Left ZeroMinimumRate
        else
            Right
                DerivedSwapParameters
                    { dspQuote = observation
                    , dspSlippageBps = slippage
                    , dspRateNumerator = rateNumerator
                    , dspRateDenominator = rateDenominator
                    , dspAmountLovelace =
                        usdmToLovelace
                            (sqrRequestedUsdm request)
                            emittedRate
                    , dspChunkSizeLovelace =
                        chunkSizeLovelace request emittedRate
                    }
  where
    SlippageBps bps = slippage
    derivedRate =
        qoQuote observation
            * ((10_000 - bps) % 10_000)
    rateDenominator = 1_000_000
    rateNumerator =
        floor (derivedRate * fromInteger rateDenominator)
    emittedRate =
        rateNumerator % rateDenominator

chunkSizeLovelace :: SwapQuoteRequest -> Rational -> Integer
chunkSizeLovelace request derivedRate =
    case sqrChunk request of
        SplitInto n ->
            dspAmount `div` toInteger n
        ChunkUsdm usdm ->
            usdmToLovelace usdm derivedRate
  where
    dspAmount =
        usdmToLovelace
            (sqrRequestedUsdm request)
            derivedRate

usdmToLovelace :: Rational -> Rational -> Integer
usdmToLovelace usdm rate =
    ceiling (usdm * 1_000_000 / rate)

parsePositiveDecimal :: Text -> Either SwapQuoteError Rational
parsePositiveDecimal raw =
    case parseUnsignedDecimal raw of
        Just value
            | value > 0 -> Right value
        _ -> Left (InvalidQuote raw)

parseUnsignedDecimal :: Text -> Maybe Rational
parseUnsignedDecimal raw
    | T.null raw =
        Nothing
    | otherwise =
        case T.splitOn "." raw of
            [whole]
                | allDigits whole ->
                    Just (fromInteger (decimalDigitsToInteger whole))
            [whole, fractional]
                | (not (T.null whole) || not (T.null fractional))
                    && allDigits whole
                    && allDigits fractional ->
                    let numeratorText = whole <> fractional
                        scale = 10 ^ T.length fractional
                    in  Just
                            ( decimalDigitsToInteger numeratorText
                                % scale
                            )
            _ ->
                Nothing
  where
    allDigits = T.all isDigit

decimalDigitsToInteger :: Text -> Integer
decimalDigitsToInteger =
    T.foldl' (\acc c -> acc * 10 + toInteger (digitToInt c)) 0
