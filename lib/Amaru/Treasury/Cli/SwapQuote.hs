{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.SwapQuote
Description : Parser for quote-derived swap preparation
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts (..)
    , SwapQuoteQuoteArg (..)
    , swapQuoteOptsP
    ) where

import Control.Applicative ((<|>))
import Data.Char (isAsciiUpper)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Options.Applicative
    ( Parser
    , ReadM
    , eitherReader
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , strOption
    )

import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.SwapQuote
    ( QuoteInput (..)
    , QuoteObservation (..)
    , SlippageBps
    , SwapQuoteRequestChunk (..)
    , parseQuoteInput
    , parseSlippageBps
    )
import Amaru.Treasury.Tx.SwapQuote.Source
    ( QuoteSource
    , parseQuoteSourceName
    , renderQuoteSourceError
    )

data SwapQuoteQuoteArg
    = SwapQuoteOverride !QuoteObservation
    | SwapQuoteSource !QuoteSource
    deriving (Eq, Show)

data SwapQuoteOpts = SwapQuoteOpts
    { sqoWalletAddr :: !Text
    , sqoMetadataPath :: !FilePath
    , sqoOutDir :: !FilePath
    , sqoScope :: !ScopeId
    , sqoRequestedUsdm :: !Text
    , sqoChunk :: !SwapQuoteRequestChunk
    , sqoQuote :: !SwapQuoteQuoteArg
    , sqoSlippageBps :: !SlippageBps
    , sqoValidityHours :: !Word8
    , sqoDescription :: !Text
    , sqoJustification :: !Text
    , sqoDestinationLabel :: !Text
    , sqoEvent :: !(Maybe Text)
    , sqoLabel :: !(Maybe Text)
    , sqoSigners :: ![Text]
    }
    deriving (Eq, Show)

swapQuoteOptsP :: Parser SwapQuoteOpts
swapQuoteOptsP =
    SwapQuoteOpts
        <$> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Wallet address (fuel + collateral)"
            )
        <*> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> strOption
            ( long "out-dir"
                <> metavar "PATH"
                <> help "Directory for intent.json, swap.cbor.hex, params.json, and logs"
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> strOption
            ( long "usdm"
                <> metavar "USDM"
                <> help "Target USDM amount"
            )
        <*> chunkP
        <*> quoteP
        <*> option
            slippageReader
            ( long "slippage-bps"
                <> metavar "INT"
                <> help "Explicit slippage policy in basis points; 0 <= INT < 10000"
            )
        <*> option
            autoWord8
            ( long "validity-hours"
                <> metavar "HOURS"
                <> help "Validity window from tip; 1..48"
            )
        <*> strOption
            ( long "description"
                <> metavar "TEXT"
                <> help "Rationale: description"
            )
        <*> strOption
            ( long "justification"
                <> metavar "TEXT"
                <> help "Rationale: justification"
            )
        <*> strOption
            ( long "destination-label"
                <> metavar "TEXT"
                <> help "Rationale: destination label"
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event override"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help "Rationale label override"
                )
            )
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> long "signer"
                    <> metavar "SCOPE|HEX"
                    <> help "Repeat for each extra signer"
                )
            )

quoteP :: Parser SwapQuoteQuoteArg
quoteP =
    adaUsdP <|> adaUsdmP <|> priceSourceP
  where
    adaUsdP =
        SwapQuoteOverride
            <$> option
                (quoteOverrideReader AdaUsdOverride)
                ( long "ada-usd"
                    <> metavar "DECIMAL"
                    <> help "Explicit ADA/USD quote override"
                )
    adaUsdmP =
        SwapQuoteOverride
            <$> option
                (quoteOverrideReader AdaUsdmOverride)
                ( long "ada-usdm"
                    <> metavar "DECIMAL"
                    <> help "Explicit ADA/USDM quote override"
                )
    priceSourceP =
        SwapQuoteSource
            <$> option
                priceSourceReader
                ( long "price-source"
                    <> metavar "SOURCE"
                    <> help "Named quote source, currently coingecko-ada-usd"
                )

chunkP :: Parser SwapQuoteRequestChunk
chunkP =
    splitP <|> chunkUsdmP
  where
    splitP =
        SplitInto
            <$> option
                positiveSplit
                ( long "split"
                    <> metavar "INT"
                    <> help "Split the order into N equal chunks"
                )
    chunkUsdmP =
        ChunkUsdm
            <$> option
                positiveDecimalReader
                ( long "chunk-usdm"
                    <> metavar "USDM"
                    <> help "Per-chunk USDM size"
                )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLowerAscii

quoteOverrideReader :: (Text -> QuoteInput) -> ReadM QuoteObservation
quoteOverrideReader mkInput =
    eitherReader $ \raw ->
        case parseQuoteInput (mkInput (T.pack raw)) of
            Right observation ->
                Right observation
            Left err ->
                Left (show err)

priceSourceReader :: ReadM QuoteSource
priceSourceReader =
    eitherReader $ \raw ->
        case parseQuoteSourceName (T.pack raw) of
            Right source ->
                Right source
            Left err ->
                Left (T.unpack (renderQuoteSourceError err))

slippageReader :: ReadM SlippageBps
slippageReader =
    eitherReader $ \raw ->
        case parseSlippageBps (Just (T.pack raw)) of
            Right slippage ->
                Right slippage
            Left err ->
                Left (show err)

positiveSplit :: ReadM Int
positiveSplit =
    eitherReader $ \raw ->
        case reads raw of
            [(n, "")]
                | n >= (1 :: Int) ->
                    Right n
            _ ->
                Left "--split must be a positive integer"

positiveDecimalReader :: ReadM Rational
positiveDecimalReader =
    eitherReader $ \raw ->
        case parseQuoteInput (AdaUsdOverride (T.pack raw)) of
            Right observation ->
                Right (qoQuote observation)
            Left err ->
                Left (show err)

autoWord8 :: ReadM Word8
autoWord8 =
    eitherReader $ \raw ->
        case reads raw of
            [(n, "")]
                | n >= (0 :: Word8) ->
                    Right n
            _ ->
                Left ("not a Word8: " <> raw)

toLowerAscii :: Char -> Char
toLowerAscii c
    | isAsciiUpper c =
        toEnum (fromEnum c + 32)
    | otherwise =
        c
