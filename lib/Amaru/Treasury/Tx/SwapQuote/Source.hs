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
    , parseCoinGeckoAdaUsdComponent
    , parseCoinGeckoUsdmUsdComponent
    , composeAdaUsdmFromComponents
    , coinGeckoRequest
    , coinGeckoUsdmRequest
    , fetchQuoteSource
    , coingeckoAdaUsdmProvider
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
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Version (showVersion)
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
import Paths_amaru_treasury_tx qualified as P
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import Data.List.NonEmpty (NonEmpty (..))

import Amaru.Treasury.Tx.SwapQuote
    ( ComponentObservation (..)
    , QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    )

data QuoteSource
    = CoinGeckoAdaUsdm
    deriving (Eq, Show)

data QuoteSourceError
    = UnknownQuoteSource !Text
    | -- | Operator passed a retired source name (e.g. @coingecko-ada-usd@).
      RetiredQuoteSource
        !Text
        !Text
        -- ^ retired name, then the replacement guidance.
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
    CoinGeckoAdaUsdm ->
        "coingecko-ada-usdm"

parseQuoteSourceName :: Text -> Either QuoteSourceError QuoteSource
parseQuoteSourceName raw =
    case T.toLower raw of
        "coingecko-ada-usdm" ->
            Right CoinGeckoAdaUsdm
        "coingecko-ada-usd" ->
            Left
                ( RetiredQuoteSource
                    raw
                    "use coingecko-ada-usdm (derived ADA/USD ÷ USDM/USD) \
                    \or pass --ada-usdm for an explicit override"
                )
        _ ->
            Left (UnknownQuoteSource raw)

{- | Parse a captured CoinGecko ADA/USD @simple/price@ response into a
component observation under the derived ADA/USDM source.
-}
parseCoinGeckoAdaUsdComponent
    :: Text -> Text -> Either QuoteSourceError ComponentObservation
parseCoinGeckoAdaUsdComponent =
    parseSimplePriceComponent "coingecko-ada-usd" "cardano" "cardano.usd"

{- | Parse a captured CoinGecko USDM/USD @simple/price@ response (id
@usdm-2@) into a component observation under the derived ADA/USDM
source.
-}
parseCoinGeckoUsdmUsdComponent
    :: Text -> Text -> Either QuoteSourceError ComponentObservation
parseCoinGeckoUsdmUsdComponent =
    parseSimplePriceComponent "coingecko-usdm-usd" "usdm-2" "usdm-2.usd"

parseSimplePriceComponent
    :: Text
    -- ^ component name (e.g. @coingecko-ada-usd@)
    -> Text
    -- ^ CoinGecko id (e.g. @cardano@ / @usdm-2@)
    -> Text
    -- ^ field path used in error messages
    -> Text
    -- ^ fetchedAt (ISO-8601)
    -> Text
    -- ^ raw response body
    -> Either QuoteSourceError ComponentObservation
parseSimplePriceComponent componentName cgId errorPath fetchedAt raw = do
    value <-
        case eitherDecodeStrict' (TE.encodeUtf8 raw) of
            Left err ->
                Left (QuoteSourceDecodeError (T.pack err))
            Right parsed ->
                Right parsed
    quote <-
        case parseEither (simplePriceParser cgId) value of
            Left err ->
                Left (QuoteSourceMissingField (T.pack err))
            Right usd
                | usd > 0 ->
                    Right (toRational usd)
                | otherwise ->
                    Left (QuoteSourceInvalidQuote errorPath)
    pure
        ComponentObservation
            { coName = componentName
            , coValue = quote
            , coFetchedAt = fetchedAt
            , coRaw = raw
            }
  where
    simplePriceParser :: Text -> Value -> Parser Scientific
    simplePriceParser cgId' =
        withObject "CoinGecko simple price" $ \root -> do
            inner <- root .: AesonKey.fromText cgId'
            withObject (T.unpack cgId') (.: "usd") inner

{- | Compose two component observations (ADA/USD and USDM/USD) into a
derived ADA/USDM 'QuoteObservation'. The @qoQuote@ is the exact
'Rational' ratio @adaUsd / usdmUsd@; the provenance captures both
components in order.
-}
composeAdaUsdmFromComponents
    :: ComponentObservation
    -- ^ ADA/USD component
    -> ComponentObservation
    -- ^ USDM/USD component
    -> QuoteObservation
composeAdaUsdmFromComponents adaUsd usdmUsd =
    QuoteObservation
        { qoPair = AdaUsdm
        , qoQuote = coValue adaUsd / coValue usdmUsd
        , qoProvenance =
            DerivedQuoteProvenance
                { dqpName = quoteSourceName CoinGeckoAdaUsdm
                , dqpComponents = adaUsd :| [usdmUsd]
                }
        }

fetchQuoteSource
    :: QuoteProvider IO
    -> QuoteSource
    -> Text
    -> IO (Either QuoteSourceError QuoteObservation)
fetchQuoteSource =
    qpFetchQuote

coingeckoAdaUsdmProvider :: QuoteProvider IO
coingeckoAdaUsdmProvider =
    QuoteProvider $ \source fetchedAt ->
        case source of
            CoinGeckoAdaUsdm ->
                fetchDerivedAdaUsdm fetchedAt

fetchDerivedAdaUsdm
    :: Text -> IO (Either QuoteSourceError QuoteObservation)
fetchDerivedAdaUsdm fetchedAt = do
    adaUsdRes <-
        fetchComponent
            fetchedAt
            coinGeckoRequest
            parseCoinGeckoAdaUsdComponent
    case adaUsdRes of
        Left err -> pure (Left err)
        Right adaUsdComp -> do
            usdmUsdRes <-
                fetchComponent
                    fetchedAt
                    coinGeckoUsdmRequest
                    parseCoinGeckoUsdmUsdComponent
            case usdmUsdRes of
                Left err -> pure (Left err)
                Right usdmUsdComp ->
                    pure
                        (Right (composeAdaUsdmFromComponents adaUsdComp usdmUsdComp))

fetchComponent
    :: Text
    -- ^ fetchedAt timestamp
    -> IO Request
    -- ^ request builder for this component
    -> (Text -> Text -> Either QuoteSourceError ComponentObservation)
    -- ^ component-specific parser
    -> IO (Either QuoteSourceError ComponentObservation)
fetchComponent fetchedAt mkRequest parseBody = do
    describeTlsTrustAnchor >>= hPutStrLn stderr
    request <- mkRequest
    result <-
        try (httpLBS request)
            :: IO (Either SomeException (Response BSL.ByteString))
    pure $
        case result of
            Left err ->
                Left
                    ( QuoteSourceFetchFailed
                        (quoteSourceName CoinGeckoAdaUsdm)
                        (T.pack (displayException err))
                    )
            Right response ->
                parseBody
                    fetchedAt
                    (decodeUtf8Lenient (getResponseBody response))

coinGeckoUrl :: String
coinGeckoUrl =
    "https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd"

coinGeckoUsdmUrl :: String
coinGeckoUsdmUrl =
    "https://api.coingecko.com/api/v3/simple/price?ids=usdm-2&vs_currencies=usd"

coinGeckoRequest :: IO Request
coinGeckoRequest =
    mkCoinGeckoRequest coinGeckoUrl

coinGeckoUsdmRequest :: IO Request
coinGeckoUsdmRequest =
    mkCoinGeckoRequest coinGeckoUsdmUrl

mkCoinGeckoRequest :: String -> IO Request
mkCoinGeckoRequest url = do
    request0 <- parseRequest url
    pure
        request0
            { responseTimeout = responseTimeoutMicro 5_000_000
            , requestHeaders =
                ("User-Agent", coinGeckoUserAgent) : requestHeaders request0
            }

{- | User-Agent advertised to outbound quote providers.

The version segment is derived from @Paths_amaru_treasury_tx@
so it tracks @amaru-treasury-tx.cabal@ across releases without a
manual bump.
-}
coinGeckoUserAgent :: ByteString
coinGeckoUserAgent =
    BS.pack $
        "amaru-treasury-tx/"
            <> showVersion P.version
            <> " (https://github.com/lambdasistemi/amaru-treasury-tx)"

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
    RetiredQuoteSource name guidance ->
        "quote source " <> name <> " retired: " <> guidance
    QuoteSourceDecodeError err ->
        "quote source decode failed: " <> err
    QuoteSourceMissingField field ->
        "quote source response missing field: " <> field
    QuoteSourceInvalidQuote field ->
        "quote source returned a non-positive quote at: " <> field
    QuoteSourceFetchFailed name err ->
        "quote source fetch failed for " <> name <> ": " <> err
