{- |
Module      : Amaru.Treasury.Cli.SwapOptions
Description : Shared swap option parser fragments
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapOptions
    ( SwapQuoteQuoteArg (..)
    , quoteP
    , slippageReader
    ) where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , ReadM
    , eitherReader
    , help
    , long
    , metavar
    , option
    )

import Amaru.Treasury.Tx.SwapQuote
    ( QuoteInput (..)
    , QuoteObservation
    , SlippageBps
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
