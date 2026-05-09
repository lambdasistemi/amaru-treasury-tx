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
    , AffordabilitySummary (..)
    , AffordabilityFailure (..)
    , SwapQuoteError (..)
    , parseQuoteInput
    , parseSlippageBps
    , deriveSwapParameters
    , generatedChunkCount
    , checkAffordability
    , renderAffordabilityFailure
    ) where

import Data.Char (digitToInt, isDigit)
import Data.Ratio (denominator, numerator, (%))
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Tx.SwapWizard (chunkCountFor)

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

data AffordabilitySummary = AffordabilitySummary
    { asDerived :: !DerivedSwapParameters
    , asChunkCount :: !Integer
    , asExtraPerChunkLovelace :: !Integer
    , asRequiredLovelace :: !Integer
    , asAvailableLovelace :: !Integer
    , asShortfallLovelace :: !Integer
    }
    deriving (Eq, Show)

newtype AffordabilityFailure
    = Unaffordable AffordabilitySummary
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

generatedChunkCount :: DerivedSwapParameters -> Integer
generatedChunkCount parameters =
    chunkCountFor
        (dspAmountLovelace parameters)
        (dspChunkSizeLovelace parameters)

checkAffordability
    :: DerivedSwapParameters
    -> Integer
    -- ^ Extra lovelace funded by the treasury for each generated chunk.
    -> Integer
    -- ^ Available treasury lovelace.
    -> Either AffordabilityFailure AffordabilitySummary
checkAffordability parameters extraPerChunkLovelace availableLovelace =
    if availableLovelace >= requiredLovelace
        then Right summary
        else Left (Unaffordable summary)
  where
    chunkCount = generatedChunkCount parameters
    requiredLovelace =
        dspAmountLovelace parameters
            + chunkCount * extraPerChunkLovelace
    shortfallLovelace =
        max 0 (requiredLovelace - availableLovelace)
    summary =
        AffordabilitySummary
            { asDerived = parameters
            , asChunkCount = chunkCount
            , asExtraPerChunkLovelace = extraPerChunkLovelace
            , asRequiredLovelace = requiredLovelace
            , asAvailableLovelace = availableLovelace
            , asShortfallLovelace = shortfallLovelace
            }

renderAffordabilityFailure :: AffordabilityFailure -> Text
renderAffordabilityFailure (Unaffordable summary) =
    T.intercalate
        "; "
        [ "swap quote affordability failed"
        , "required=" <> formatAda (asRequiredLovelace summary)
        , "available=" <> formatAda (asAvailableLovelace summary)
        , "quote=" <> formatQuote (dspQuote derived)
        , "slippage=" <> formatSlippage (dspSlippageBps derived)
        , "shortfall=" <> formatAda (asShortfallLovelace summary)
        ]
  where
    derived = asDerived summary

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

formatAda :: Integer -> Text
formatAda lovelace =
    decimal
        <> " ADA ("
        <> tshow lovelace
        <> " lovelace)"
  where
    (whole, fractional) = lovelace `divMod` 1_000_000
    decimal =
        tshow whole
            <> "."
            <> leftPad 6 (tshow fractional)

formatQuote :: QuoteObservation -> Text
formatQuote observation =
    formatRationalDecimal (qoQuote observation)
        <> " "
        <> case qoPair observation of
            AdaUsd -> "ADA/USD"
            AdaUsdm -> "ADA/USDM"

formatSlippage :: SlippageBps -> Text
formatSlippage (SlippageBps bps) =
    tshow bps <> " bps"

formatRationalDecimal :: Rational -> Text
formatRationalDecimal value =
    case finiteDecimalScale (denominator value) of
        Nothing ->
            tshow (numerator value) <> "/" <> tshow (denominator value)
        Just scale ->
            let scaledNumerator =
                    numerator value
                        * (10 ^ scale)
                        `div` denominator value
                raw = tshow scaledNumerator
            in  if scale == 0
                    then raw
                    else trimTrailingZeros (whole raw scale <> "." <> frac raw scale)
  where
    whole raw scale =
        let len = T.length raw
        in  if len <= scale
                then "0"
                else T.take (len - scale) raw
    frac raw scale =
        let len = T.length raw
            padded = leftPad scale raw
        in  T.drop (max 0 (len - scale)) padded

finiteDecimalScale :: Integer -> Maybe Int
finiteDecimalScale denominatorValue =
    if remainder == 1
        then Just (max twos fives)
        else Nothing
  where
    (twos, withoutTwos) = factorCount 2 denominatorValue
    (fives, remainder) = factorCount 5 withoutTwos

factorCount :: Integer -> Integer -> (Int, Integer)
factorCount factor =
    go 0
  where
    go count value
        | value > 0 && value `mod` factor == 0 =
            go (count + 1) (value `div` factor)
        | otherwise =
            (count, value)

leftPad :: Int -> Text -> Text
leftPad width text =
    T.replicate (max 0 (width - T.length text)) "0" <> text

trimTrailingZeros :: Text -> Text
trimTrailingZeros text =
    case T.breakOn "." text of
        (_, "") ->
            text
        (whole, fractionalWithDot) ->
            let fractional =
                    T.drop 1 fractionalWithDot
                trimmed =
                    T.dropWhileEnd (== '0') fractional
            in  if T.null trimmed
                    then whole
                    else whole <> "." <> trimmed

tshow :: (Show a) => a -> Text
tshow = T.pack . show
