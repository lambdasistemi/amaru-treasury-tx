{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.SwapQuote.Source
Description : Quote source parsing and production providers
License     : Apache-2.0

The named-source surface is deliberately small: CI exercises captured
responses, while production performs one live request for the approved
ADA/USD provider.
-}
module Amaru.Treasury.Tx.SwapQuote.Source
    ( QuoteSource (..)
    , QuoteSourceError (..)
    , QuoteProvider (..)
    , quoteSourceName
    , parseQuoteSourceName
    , parseCoinGeckoAdaUsdResponse
    , coinGeckoRequest
    , fetchQuoteSource
    , coingeckoAdaUsdProvider
    , renderQuoteSourceError
    , describeTlsTrustAnchor
    ) where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson
    ( Value
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Network.HTTP.Client
    ( Request (responseTimeout)
    , requestHeaders
    , responseTimeoutMicro
    )
import Network.HTTP.Simple
    ( Response
    , getResponseBody
    , httpLBS
    , parseRequest
    )
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import Amaru.Treasury.Tx.SwapQuote
    ( QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    )

data QuoteSource
    = CoinGeckoAdaUsd
    deriving (Eq, Show)

data QuoteSourceError
    = UnknownQuoteSource !Text
    | NamedAdaUsdmSourceUnavailable !Text
    | QuoteSourceDecodeError !Text
    | QuoteSourceMissingField !Text
    | QuoteSourceInvalidQuote !Text
    | QuoteSourceFetchFailed !Text !Text
    deriving (Eq, Show)

newtype QuoteProvider m = QuoteProvider
    { qpFetchQuote
        :: QuoteSource
        -> Text
        -> m (Either QuoteSourceError QuoteObservation)
    }

quoteSourceName :: QuoteSource -> Text
quoteSourceName = \case
    CoinGeckoAdaUsd ->
        "coingecko-ada-usd"

parseQuoteSourceName :: Text -> Either QuoteSourceError QuoteSource
parseQuoteSourceName raw =
    case T.toLower raw of
        "coingecko-ada-usd" ->
            Right CoinGeckoAdaUsd
        name
            | "usdm" `T.isInfixOf` name ->
                Left (NamedAdaUsdmSourceUnavailable raw)
        _ ->
            Left (UnknownQuoteSource raw)

parseCoinGeckoAdaUsdResponse
    :: Text -> Text -> Either QuoteSourceError QuoteObservation
parseCoinGeckoAdaUsdResponse fetchedAt raw = do
    value <-
        case eitherDecodeStrict' (TE.encodeUtf8 raw) of
            Left err ->
                Left (QuoteSourceDecodeError (T.pack err))
            Right parsed ->
                Right parsed
    quote <-
        case parseEither coingeckoUsd value of
            Left err ->
                Left (QuoteSourceMissingField (T.pack err))
            Right usd
                | usd > 0 ->
                    Right (toRational usd)
                | otherwise ->
                    Left (QuoteSourceInvalidQuote "cardano.usd")
    pure
        QuoteObservation
            { qoPair = AdaUsd
            , qoQuote = quote
            , qoProvenance =
                QuoteSourceProvenance
                    { qspName = quoteSourceName CoinGeckoAdaUsd
                    , qspFetchedAt = fetchedAt
                    , qspRaw = raw
                    }
            }
  where
    coingeckoUsd :: Value -> Parser Scientific
    coingeckoUsd =
        withObject "CoinGecko simple price" $ \root -> do
            cardano <- root .: "cardano"
            withObject "cardano" (.: "usd") cardano

fetchQuoteSource
    :: QuoteProvider IO
    -> QuoteSource
    -> Text
    -> IO (Either QuoteSourceError QuoteObservation)
fetchQuoteSource =
    qpFetchQuote

coingeckoAdaUsdProvider :: QuoteProvider IO
coingeckoAdaUsdProvider =
    QuoteProvider $ \source fetchedAt ->
        case source of
            CoinGeckoAdaUsd ->
                fetchCoinGecko fetchedAt

fetchCoinGecko
    :: Text -> IO (Either QuoteSourceError QuoteObservation)
fetchCoinGecko fetchedAt = do
    describeTlsTrustAnchor >>= hPutStrLn stderr
    request <- coinGeckoRequest
    result <-
        try (httpLBS request)
            :: IO (Either SomeException (Response BSL.ByteString))
    pure $
        case result of
            Left err ->
                Left
                    ( QuoteSourceFetchFailed
                        (quoteSourceName CoinGeckoAdaUsd)
                        (T.pack (displayException err))
                    )
            Right response ->
                parseCoinGeckoAdaUsdResponse
                    fetchedAt
                    (decodeUtf8Lenient (getResponseBody response))

coinGeckoUrl :: String
coinGeckoUrl =
    "https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd"

coinGeckoRequest :: IO Request
coinGeckoRequest = do
    request0 <- parseRequest coinGeckoUrl
    pure
        request0
            { responseTimeout = responseTimeoutMicro 5_000_000
            , requestHeaders =
                ("User-Agent", coinGeckoUserAgent) : requestHeaders request0
            }

coinGeckoUserAgent :: ByteString
coinGeckoUserAgent =
    "amaru-treasury-tx/0.2.1.1 (https://github.com/lambdasistemi/amaru-treasury-tx)"

{- | Describe the TLS trust anchor that the next outbound
HTTPS request will use, by reading @SSL_CERT_FILE@ and
@SYSTEM_CERTIFICATE_PATH@ from the environment.

The release wrapper @--set-default@s these to a
@nixpkgs.cacert@ bundle baked into the AppImage / DEB /
RPM closure, so on a clean operator host the announced
path resolves to a known-Mozilla CA bundle. An operator
that exports either env beforehand sees their own value
echoed, making it auditable that their override took
effect.

This is emitted to stderr once per live quote fetch so
the trust anchor is recorded in every transcript that
contains a quote source response.
-}
describeTlsTrustAnchor :: IO String
describeTlsTrustAnchor = do
    sslCertFile <- fromMaybe "<unset>" <$> lookupEnv "SSL_CERT_FILE"
    systemPath <-
        fromMaybe "<unset>" <$> lookupEnv "SYSTEM_CERTIFICATE_PATH"
    pure $
        "swap-quote: TLS trust anchor"
            <> " SSL_CERT_FILE="
            <> sslCertFile
            <> " SYSTEM_CERTIFICATE_PATH="
            <> systemPath

decodeUtf8Lenient :: BSL.ByteString -> Text
decodeUtf8Lenient =
    TE.decodeUtf8With lenientDecode . BSL.toStrict

renderQuoteSourceError :: QuoteSourceError -> Text
renderQuoteSourceError = \case
    UnknownQuoteSource name ->
        "unknown quote source: " <> name
    NamedAdaUsdmSourceUnavailable name ->
        "named ADA/USDM quote source is future work: "
            <> name
            <> "; use --ada-usdm for explicit overrides"
    QuoteSourceDecodeError err ->
        "quote source decode failed: " <> err
    QuoteSourceMissingField field ->
        "quote source response missing field: " <> field
    QuoteSourceInvalidQuote field ->
        "quote source returned a non-positive quote at: " <> field
    QuoteSourceFetchFailed name err ->
        "quote source fetch failed for " <> name <> ": " <> err
