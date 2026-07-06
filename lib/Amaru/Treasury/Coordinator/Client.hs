{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Coordinator.Client
Description : OpenAPI-shaped client for the coordinator /v1 contract
License     : Apache-2.0

The module keeps the wire carriers close to
@cardano-multisig/openapi/v1.yaml@ and exposes a small injectable
transport so unit tests can assert request construction without a live
coordinator.
-}
module Amaru.Treasury.Coordinator.Client
    ( -- * Base URL
      CoordinatorBaseUrl
    , normalizeCoordinatorBaseUrl

      -- * Transport
    , CoordinatorTransport (..)
    , CoordinatorHttpRequest (..)
    , CoordinatorHttpResponse (..)
    , httpCoordinatorTransport

      -- * Errors
    , CoordinatorClientError (..)
    , CoordinatorError (..)
    , renderCoordinatorClientError

      -- * Requests and responses
    , FeeQuoteRequest (..)
    , FeeQuote (..)
    , FeeStatus (..)
    , FeeReason (..)
    , PublishRequest (..)
    , Entry (..)
    , Liveness (..)
    , EntryStatus (..)
    , WitnessRequest (..)
    , WitnessResult (..)
    , Receipt (..)

      -- * Actions
    , quoteFee
    , getFeeStatus
    , publishEntry
    , addWitness
    , submitEntry
    ) where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value
    , eitherDecode'
    , encode
    , object
    , pairs
    , withObject
    , withText
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Network.HTTP.Client
    ( Request (method, requestBody, responseTimeout)
    , RequestBody (RequestBodyLBS)
    , requestHeaders
    , responseTimeoutMicro
    )
import Network.HTTP.Simple
    ( getResponseBody
    , getResponseStatus
    , httpLBS
    , parseRequest
    )
import Network.HTTP.Types.Header
    ( HeaderName
    , hAccept
    , hContentType
    , hUserAgent
    )
import Network.HTTP.Types.Method
    ( methodGet
    , methodPost
    )
import Network.HTTP.Types.Status (statusCode)
import Paths_amaru_treasury_tx qualified as P

-- | Normalized coordinator service root without a trailing @/v1@.
newtype CoordinatorBaseUrl = CoordinatorBaseUrl
    { coordinatorBaseUrlRoot :: Text
    }
    deriving stock (Eq, Show)

-- | A transport-level request after endpoint path construction.
data CoordinatorHttpRequest = CoordinatorHttpRequest
    { chrMethod :: ByteString
    , chrUrl :: Text
    , chrPath :: Text
    , chrBody :: Maybe BSL.ByteString
    }
    deriving stock (Eq, Show)

-- | A transport-level response with status and raw body.
data CoordinatorHttpResponse = CoordinatorHttpResponse
    { chrStatus :: Int
    , chrBody :: BSL.ByteString
    }
    deriving stock (Eq, Show)

-- | Injectable coordinator transport.
newtype CoordinatorTransport m = CoordinatorTransport
    { runCoordinatorRequest
        :: CoordinatorHttpRequest
        -> m (Either CoordinatorClientError CoordinatorHttpResponse)
    }

data CoordinatorClientError
    = CoordinatorInvalidBaseUrl !Text
    | CoordinatorTransportFailed !Text
    | CoordinatorDecodeFailed !Text
    | CoordinatorResponseError !Int !CoordinatorError
    deriving stock (Eq, Show)

data CoordinatorError = CoordinatorError
    { ceCode :: Text
    , ceMessage :: Text
    , ceDetail :: Maybe Value
    }
    deriving stock (Eq, Show)

newtype FeeQuoteRequest = FeeQuoteRequest
    { fqrTransaction :: Text
    }
    deriving stock (Eq, Show)

data FeeQuote = FeeQuote
    { fqBodyHash :: Text
    , fqRequiredFeeLovelace :: Integer
    , fqFeeAddress :: Text
    , fqTag :: Text
    , fqInvalidHereafter :: Integer
    }
    deriving stock (Eq, Show)

data FeeStatus = FeeStatus
    { fsBodyHash :: Text
    , fsPaid :: Bool
    , fsReason :: Maybe FeeReason
    , fsFeePayment :: Maybe Text
    }
    deriving stock (Eq, Show)

data FeeReason
    = FeeNotSeen
    | FeeUnconfirmed
    | FeeInsufficient
    | FeeMetadataMalformed
    deriving stock (Eq, Show)

data PublishRequest = PublishRequest
    { prTransaction :: Text
    , prFeePayment :: Maybe Text
    }
    deriving stock (Eq, Show)

data Entry = Entry
    { eEntryId :: Text
    , eTransaction :: Maybe Text
    , eRequiredSigners :: [Text]
    , eWitnesses :: [Text]
    , eMissing :: [Text]
    , eLiveness :: Maybe Liveness
    , eInvalidHereafter :: Integer
    , eStatus :: EntryStatus
    }
    deriving stock (Eq, Show)

data Liveness = Liveness
    { lInputsUnspent :: Bool
    , lPhase1Ok :: Bool
    }
    deriving stock (Eq, Show)

data EntryStatus
    = Collecting
    | Ready
    | Submitted
    | Expired
    deriving stock (Eq, Show)

newtype WitnessRequest = WitnessRequest
    { wrqWitness :: Text
    }
    deriving stock (Eq, Show)

data WitnessResult = WitnessResult
    { wrWitnesses :: [Text]
    , wrMissing :: [Text]
    , wrStatus :: EntryStatus
    }
    deriving stock (Eq, Show)

data Receipt = Receipt
    { rTxId :: Text
    , rSubmittedAt :: Text
    }
    deriving stock (Eq, Show)

normalizeCoordinatorBaseUrl
    :: Text -> Either CoordinatorClientError CoordinatorBaseUrl
normalizeCoordinatorBaseUrl raw =
    case stripV1 (dropTrailingSlash (T.strip raw)) of
        "" -> Left (CoordinatorInvalidBaseUrl raw)
        normalized -> Right (CoordinatorBaseUrl normalized)
  where
    dropTrailingSlash =
        T.dropWhileEnd (== '/')
    stripV1 url =
        fromMaybe url (T.stripSuffix "/v1" url)

httpCoordinatorTransport :: CoordinatorTransport IO
httpCoordinatorTransport =
    CoordinatorTransport $ \req -> do
        result <-
            try (sendHttpRequest req)
                :: IO (Either SomeException CoordinatorHttpResponse)
        pure $
            case result of
                Left err ->
                    Left
                        ( CoordinatorTransportFailed
                            (T.pack (displayException err))
                        )
                Right response ->
                    Right response

quoteFee
    :: (Monad m)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> FeeQuoteRequest
    -> m (Either CoordinatorClientError FeeQuote)
quoteFee transport base =
    sendJson transport base methodPost "/v1/fee-quote" 200 . Just

getFeeStatus
    :: (Monad m)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> Text
    -> m (Either CoordinatorClientError FeeStatus)
getFeeStatus transport base bodyHash =
    sendJson
        transport
        base
        methodGet
        ("/v1/fee-status/" <> bodyHash)
        200
        (Nothing :: Maybe Value)

publishEntry
    :: (Monad m)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> PublishRequest
    -> m (Either CoordinatorClientError Entry)
publishEntry transport base =
    sendJson transport base methodPost "/v1/entries" 201 . Just

addWitness
    :: (Monad m)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> Text
    -> WitnessRequest
    -> m (Either CoordinatorClientError WitnessResult)
addWitness transport base entryId =
    sendJson
        transport
        base
        methodPost
        ("/v1/entries/" <> entryId <> "/witnesses")
        200
        . Just

submitEntry
    :: (Monad m)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> Text
    -> m (Either CoordinatorClientError Receipt)
submitEntry transport base entryId =
    sendJson
        transport
        base
        methodPost
        ("/v1/entries/" <> entryId <> "/submit")
        200
        (Nothing :: Maybe Value)

sendJson
    :: (Monad m, ToJSON request, FromJSON response)
    => CoordinatorTransport m
    -> CoordinatorBaseUrl
    -> ByteString
    -> Text
    -> Int
    -> Maybe request
    -> m (Either CoordinatorClientError response)
sendJson (CoordinatorTransport send) base method' path expectedStatus payload = do
    response <- send (mkRequest base method' path payload)
    pure $ do
        httpResponse <- response
        case httpResponse of
            CoordinatorHttpResponse{chrStatus = status, chrBody = body}
                | status == expectedStatus ->
                    decodeResponse body
                | otherwise ->
                    Left (decodeCoordinatorError status body)

mkRequest
    :: (ToJSON request)
    => CoordinatorBaseUrl
    -> ByteString
    -> Text
    -> Maybe request
    -> CoordinatorHttpRequest
mkRequest (CoordinatorBaseUrl root) method' path payload =
    CoordinatorHttpRequest
        { chrMethod = method'
        , chrUrl = root <> path
        , chrPath = path
        , chrBody = encode <$> payload
        }

decodeResponse
    :: (FromJSON a) => BSL.ByteString -> Either CoordinatorClientError a
decodeResponse body =
    case eitherDecode' body of
        Left err -> Left (CoordinatorDecodeFailed (T.pack err))
        Right value -> Right value

decodeCoordinatorError
    :: Int -> BSL.ByteString -> CoordinatorClientError
decodeCoordinatorError status body =
    case eitherDecode' body of
        Left err ->
            CoordinatorDecodeFailed
                ( "coordinator error response decode failed with HTTP "
                    <> T.pack (show status)
                    <> ": "
                    <> T.pack err
                )
        Right err ->
            CoordinatorResponseError status err

sendHttpRequest
    :: CoordinatorHttpRequest -> IO CoordinatorHttpResponse
sendHttpRequest req@CoordinatorHttpRequest{chrBody = body} = do
    request0 <- parseRequest (T.unpack (chrUrl req))
    let request =
            request0
                { method = chrMethod req
                , requestBody = maybe mempty RequestBodyLBS body
                , responseTimeout = responseTimeoutMicro 5_000_000
                , requestHeaders =
                    requestHeadersFor body <> requestHeaders request0
                }
    response <- httpLBS request
    pure
        CoordinatorHttpResponse
            { chrStatus = statusCode (getResponseStatus response)
            , chrBody = getResponseBody response
            }

requestHeadersFor
    :: Maybe BSL.ByteString -> [(HeaderName, ByteString)]
requestHeadersFor body =
    case body of
        Nothing -> commonHeaders
        Just{} -> (hContentType, "application/json") : commonHeaders
  where
    commonHeaders =
        [ (hAccept, "application/json")
        , (hUserAgent, coordinatorUserAgent)
        ]

coordinatorUserAgent :: ByteString
coordinatorUserAgent =
    BS.pack $
        "amaru-treasury-tx/"
            <> showVersion P.version
            <> " (https://github.com/lambdasistemi/amaru-treasury-tx)"

renderCoordinatorClientError :: CoordinatorClientError -> Text
renderCoordinatorClientError = \case
    CoordinatorInvalidBaseUrl raw ->
        "invalid coordinator base URL: " <> raw
    CoordinatorTransportFailed err ->
        "coordinator request failed: " <> err
    CoordinatorDecodeFailed err ->
        "coordinator response decode failed: " <> err
    CoordinatorResponseError status err ->
        "coordinator returned HTTP "
            <> T.pack (show status)
            <> " "
            <> ceCode err
            <> ": "
            <> ceMessage err

instance ToJSON FeeQuoteRequest where
    toJSON request =
        object ["transaction" .= fqrTransaction request]
    toEncoding request =
        pairs ("transaction" .= fqrTransaction request)

instance FromJSON FeeQuoteRequest where
    parseJSON =
        withObject "FeeQuoteRequest" $ \o ->
            FeeQuoteRequest <$> o .: "transaction"

instance ToJSON FeeQuote where
    toJSON quote =
        object
            [ "body_hash" .= fqBodyHash quote
            , "required_fee_lovelace" .= fqRequiredFeeLovelace quote
            , "fee_address" .= fqFeeAddress quote
            , "tag" .= fqTag quote
            , "invalid_hereafter" .= fqInvalidHereafter quote
            ]

instance FromJSON FeeQuote where
    parseJSON =
        withObject "FeeQuote" $ \o ->
            FeeQuote
                <$> o .: "body_hash"
                <*> o .: "required_fee_lovelace"
                <*> o .: "fee_address"
                <*> o .: "tag"
                <*> o .: "invalid_hereafter"

instance ToJSON FeeStatus where
    toJSON status =
        object
            [ "body_hash" .= fsBodyHash status
            , "paid" .= fsPaid status
            , "reason" .= fsReason status
            , "fee_payment" .= fsFeePayment status
            ]

instance FromJSON FeeStatus where
    parseJSON =
        withObject "FeeStatus" $ \o ->
            FeeStatus
                <$> o .: "body_hash"
                <*> o .: "paid"
                <*> o .:? "reason"
                <*> o .:? "fee_payment"

instance ToJSON FeeReason where
    toJSON =
        \case
            FeeNotSeen -> "fee_not_seen"
            FeeUnconfirmed -> "fee_unconfirmed"
            FeeInsufficient -> "fee_insufficient"
            FeeMetadataMalformed -> "fee_metadata_malformed"

instance FromJSON FeeReason where
    parseJSON =
        withText "FeeReason" $ \case
            "fee_not_seen" -> pure FeeNotSeen
            "fee_unconfirmed" -> pure FeeUnconfirmed
            "fee_insufficient" -> pure FeeInsufficient
            "fee_metadata_malformed" -> pure FeeMetadataMalformed
            unknown -> fail ("unknown fee reason: " <> T.unpack unknown)

instance ToJSON PublishRequest where
    toJSON request =
        object $
            [ "transaction" .= prTransaction request
            ]
                <> maybe [] (\txIn -> ["fee_payment" .= txIn]) (prFeePayment request)
    toEncoding request =
        pairs $
            "transaction"
                .= prTransaction request
                <> maybe
                    mempty
                    ("fee_payment" .=)
                    (prFeePayment request)

instance FromJSON PublishRequest where
    parseJSON =
        withObject "PublishRequest" $ \o ->
            PublishRequest
                <$> o .: "transaction"
                <*> o .:? "fee_payment"

instance ToJSON Entry where
    toJSON entry =
        object
            [ "entry_id" .= eEntryId entry
            , "transaction" .= eTransaction entry
            , "required_signers" .= eRequiredSigners entry
            , "witnesses" .= eWitnesses entry
            , "missing" .= eMissing entry
            , "liveness" .= eLiveness entry
            , "invalid_hereafter" .= eInvalidHereafter entry
            , "status" .= eStatus entry
            ]

instance FromJSON Entry where
    parseJSON =
        withObject "Entry" $ \o ->
            Entry
                <$> o .: "entry_id"
                <*> o .:? "transaction"
                <*> o .: "required_signers"
                <*> o .: "witnesses"
                <*> o .: "missing"
                <*> o .:? "liveness"
                <*> o .: "invalid_hereafter"
                <*> o .: "status"

instance ToJSON Liveness where
    toJSON liveness =
        object
            [ "inputs_unspent" .= lInputsUnspent liveness
            , "phase1_ok" .= lPhase1Ok liveness
            ]

instance FromJSON Liveness where
    parseJSON =
        withObject "Liveness" $ \o ->
            Liveness
                <$> o .: "inputs_unspent"
                <*> o .: "phase1_ok"

instance ToJSON EntryStatus where
    toJSON =
        \case
            Collecting -> "collecting"
            Ready -> "ready"
            Submitted -> "submitted"
            Expired -> "expired"

instance FromJSON EntryStatus where
    parseJSON =
        withText "EntryStatus" $ \case
            "collecting" -> pure Collecting
            "ready" -> pure Ready
            "submitted" -> pure Submitted
            "expired" -> pure Expired
            unknown -> fail ("unknown entry status: " <> T.unpack unknown)

instance ToJSON WitnessRequest where
    toJSON request =
        object ["witness" .= wrqWitness request]
    toEncoding request =
        pairs ("witness" .= wrqWitness request)

instance FromJSON WitnessRequest where
    parseJSON =
        withObject "WitnessRequest" $ \o ->
            WitnessRequest <$> o .: "witness"

instance ToJSON WitnessResult where
    toJSON result =
        object
            [ "witnesses" .= wrWitnesses result
            , "missing" .= wrMissing result
            , "status" .= wrStatus result
            ]

instance FromJSON WitnessResult where
    parseJSON =
        withObject "WitnessResult" $ \o ->
            WitnessResult
                <$> o .: "witnesses"
                <*> o .: "missing"
                <*> o .: "status"

instance ToJSON Receipt where
    toJSON receipt =
        object
            [ "tx_id" .= rTxId receipt
            , "submitted_at" .= rSubmittedAt receipt
            ]

instance FromJSON Receipt where
    parseJSON =
        withObject "Receipt" $ \o ->
            Receipt
                <$> o .: "tx_id"
                <*> o .: "submitted_at"

instance ToJSON CoordinatorError where
    toJSON err =
        object
            [ "error"
                .= object
                    ( [ "code" .= ceCode err
                      , "message" .= ceMessage err
                      ]
                        <> maybe [] (\detail -> ["detail" .= detail]) (ceDetail err)
                    )
            ]

instance FromJSON CoordinatorError where
    parseJSON =
        withObject "CoordinatorErrorEnvelope" $ \root -> do
            err <- root .: "error"
            withObject "CoordinatorError" parseError err
      where
        parseError o =
            CoordinatorError
                <$> o .: "code"
                <*> o .: "message"
                <*> o .:? "detail"
