{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Coordinator.ClientSpec
Description : Unit tests for the coordinator /v1 wire client
License     : Apache-2.0
-}
module Amaru.Treasury.Coordinator.ClientSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
    ( Value
    , decode
    , encode
    , object
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Text (Text)
import Network.HTTP.Types.Method
    ( methodGet
    , methodPost
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Coordinator.Client
    ( CoordinatorBaseUrl
    , CoordinatorClientError (..)
    , CoordinatorError (..)
    , CoordinatorHttpRequest (..)
    , CoordinatorHttpResponse (..)
    , CoordinatorTransport (..)
    , Entry (..)
    , EntryStatus (..)
    , FeeQuote (..)
    , FeeQuoteRequest (..)
    , FeeReason (..)
    , FeeStatus (..)
    , Liveness (..)
    , PublishRequest (..)
    , Receipt (..)
    , WitnessRequest (..)
    , WitnessResult (..)
    , addWitness
    , getFeeStatus
    , normalizeCoordinatorBaseUrl
    , publishEntry
    , quoteFee
    , submitEntry
    )

spec :: Spec
spec = describe "Amaru.Treasury.Coordinator.Client" $ do
    describe "JSON wire shapes" $ do
        it "encodes fee quote requests and decodes fee quotes" $ do
            encode (FeeQuoteRequest sampleTx)
                `shouldBe` "{\"transaction\":\"" <> textJson sampleTx <> "\"}"

            decode
                "{\
                \\"body_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\
                \\"required_fee_lovelace\":4200000,\
                \\"fee_address\":\"addr1fee\",\
                \\"tag\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\
                \\"invalid_hereafter\":123456\
                \}"
                `shouldBe` Just sampleFeeQuote

        it "encodes publish and witness requests with OpenAPI field names" $ do
            encode (PublishRequest sampleTx (Just sampleTxIn))
                `shouldBe` "{\"transaction\":\""
                    <> textJson sampleTx
                    <> "\",\"fee_payment\":\""
                    <> textJson sampleTxIn
                    <> "\"}"

            encode (WitnessRequest sampleWitness)
                `shouldBe` "{\"witness\":\"" <> textJson sampleWitness <> "\"}"

        it "decodes status, entry, witness result, and receipt responses" $ do
            decode
                "{\
                \\"body_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\
                \\"paid\":false,\
                \\"reason\":\"fee_not_seen\",\
                \\"fee_payment\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0\"\
                \}"
                `shouldBe` Just
                    FeeStatus
                        { fsBodyHash = sampleBodyHash
                        , fsPaid = False
                        , fsReason = Just FeeNotSeen
                        , fsFeePayment = Just sampleTxIn
                        }

            decode sampleEntryJson `shouldBe` Just sampleEntry
            decode sampleWitnessResultJson
                `shouldBe` Just
                    WitnessResult
                        { wrWitnesses = [sampleSigner]
                        , wrMissing = []
                        , wrStatus = Ready
                        }
            decode
                "{\
                \\"tx_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\
                \\"submitted_at\":\"2026-07-06T12:34:56Z\"\
                \}"
                `shouldBe` Just
                    Receipt
                        { rTxId = sampleBodyHash
                        , rSubmittedAt = "2026-07-06T12:34:56Z"
                        }

        it "decodes OpenAPI error envelopes into a typed error" $ do
            decode
                "{\
                \\"error\":{\
                \\"code\":\"fee_missing\",\
                \\"message\":\"fee payment not found\"\
                \}\
                \}"
                `shouldBe` Just
                    CoordinatorError
                        { ceCode = "fee_missing"
                        , ceMessage = "fee payment not found"
                        , ceDetail = Nothing
                        }

            decode
                "{\
                \\"error\":{\
                \\"code\":\"invalid_tx\",\
                \\"message\":\"transaction is invalid\",\
                \\"detail\":{\"field\":\"transaction\"}\
                \}\
                \}"
                `shouldBe` Just
                    CoordinatorError
                        { ceCode = "invalid_tx"
                        , ceMessage = "transaction is invalid"
                        , ceDetail = Just (object ["field" .= ("transaction" :: Text)])
                        }

    describe "base URL normalization" $ do
        it "accepts a service root without double-prefixing /v1" $ do
            base <-
                expectRight (normalizeCoordinatorBaseUrl "https://coord.example")
            req <-
                captureOne $ \transport ->
                    quoteFee transport base (FeeQuoteRequest sampleTx)
            chrUrl req `shouldBe` "https://coord.example/v1/fee-quote"
            chrPath req `shouldBe` "/v1/fee-quote"

        it "accepts an already-versioned base without double-prefixing /v1" $ do
            base <-
                expectRight (normalizeCoordinatorBaseUrl "https://coord.example/v1/")
            req <-
                captureOne $ \transport ->
                    quoteFee transport base (FeeQuoteRequest sampleTx)
            chrUrl req `shouldBe` "https://coord.example/v1/fee-quote"
            chrPath req `shouldBe` "/v1/fee-quote"

    describe "client request construction" $ do
        it "POSTs /v1/fee-quote with a transaction body" $ do
            base <- sampleBase
            req <-
                captureOne $ \transport ->
                    quoteFee transport base (FeeQuoteRequest sampleTx)
            requestShape req
                `shouldBe` (methodPost, "/v1/fee-quote", Just (transactionJson sampleTx))

        it "GETs /v1/fee-status/{body_hash}" $ do
            base <- sampleBase
            req <-
                captureOne $ \transport ->
                    getFeeStatus transport base sampleBodyHash
            requestShape req
                `shouldBe` (methodGet, "/v1/fee-status/" <> sampleBodyHash, Nothing)

        it "POSTs /v1/entries with optional fee_payment" $ do
            base <- sampleBase
            req <-
                captureOne $ \transport ->
                    publishEntry
                        transport
                        base
                        (PublishRequest sampleTx (Just sampleTxIn))
            requestShape req
                `shouldBe` ( methodPost
                           , "/v1/entries"
                           , Just
                                ( object
                                    [ "transaction" .= sampleTx
                                    , "fee_payment" .= sampleTxIn
                                    ]
                                )
                           )

        it "POSTs /v1/entries/{id}/witnesses with a witness body" $ do
            base <- sampleBase
            req <-
                captureOne $ \transport ->
                    addWitness
                        transport
                        base
                        sampleBodyHash
                        (WitnessRequest sampleWitness)
            requestShape req
                `shouldBe` ( methodPost
                           , "/v1/entries/" <> sampleBodyHash <> "/witnesses"
                           , Just (object ["witness" .= sampleWitness])
                           )

        it "POSTs /v1/entries/{id}/submit without a JSON body" $ do
            base <- sampleBase
            req <-
                captureOne $ \transport ->
                    submitEntry transport base sampleBodyHash
            requestShape req
                `shouldBe` ( methodPost
                           , "/v1/entries/" <> sampleBodyHash <> "/submit"
                           , Nothing
                           )

        it "maps non-2xx coordinator responses to the typed Left path" $ do
            base <- sampleBase
            result <-
                quoteFee
                    errorTransport
                    base
                    (FeeQuoteRequest sampleTx)
            result
                `shouldBe` Left
                    ( CoordinatorResponseError
                        422
                        CoordinatorError
                            { ceCode = "invalid_tx"
                            , ceMessage = "transaction is invalid"
                            , ceDetail =
                                Just (object ["field" .= ("transaction" :: Text)])
                            }
                    )

sampleBase :: IO CoordinatorBaseUrl
sampleBase =
    expectRight (normalizeCoordinatorBaseUrl "https://coord.example")

captureOne
    :: (CoordinatorTransport IO -> IO (Either e a))
    -> IO CoordinatorHttpRequest
captureOne action = do
    seen <- newIORef []
    result <- action (recordingTransport seen)
    case result of
        Left _ ->
            expectationFailure "client action returned an unexpected error"
        Right _ ->
            pure ()
    requests <- readIORef seen
    case requests of
        [req] -> pure req
        other ->
            expectationFailure
                ("expected one request, saw " <> show (length other))
                >> fail "unexpected request count"

recordingTransport
    :: IORef [CoordinatorHttpRequest] -> CoordinatorTransport IO
recordingTransport seen =
    CoordinatorTransport $ \req -> do
        liftIO $
            atomicModifyIORef' seen $ \requests ->
                (requests <> [req], ())
        pure (Right (stubResponse req))

errorTransport :: CoordinatorTransport IO
errorTransport =
    CoordinatorTransport $ \_req ->
        pure
            ( Right
                CoordinatorHttpResponse
                    { chrStatus = 422
                    , chrBody =
                        "{\
                        \\"error\":{\
                        \\"code\":\"invalid_tx\",\
                        \\"message\":\"transaction is invalid\",\
                        \\"detail\":{\"field\":\"transaction\"}\
                        \}\
                        \}"
                    }
            )

stubResponse :: CoordinatorHttpRequest -> CoordinatorHttpResponse
stubResponse req =
    CoordinatorHttpResponse
        { chrStatus = if chrPath req == "/v1/entries" then 201 else 200
        , chrBody =
            case chrPath req of
                "/v1/fee-quote" -> encode sampleFeeQuote
                "/v1/fee-status/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ->
                    encode
                        FeeStatus
                            { fsBodyHash = sampleBodyHash
                            , fsPaid = True
                            , fsReason = Nothing
                            , fsFeePayment = Just sampleTxIn
                            }
                "/v1/entries" -> encode sampleEntry
                "/v1/entries/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/witnesses" ->
                    encode
                        WitnessResult
                            { wrWitnesses = [sampleSigner]
                            , wrMissing = []
                            , wrStatus = Ready
                            }
                "/v1/entries/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/submit" ->
                    encode
                        Receipt
                            { rTxId = sampleBodyHash
                            , rSubmittedAt = "2026-07-06T12:34:56Z"
                            }
                _ -> "{\"error\":{\"code\":\"not_found\",\"message\":\"not found\"}}"
        }

requestShape
    :: CoordinatorHttpRequest -> (ByteString, Text, Maybe Value)
requestShape CoordinatorHttpRequest{chrMethod, chrPath, chrBody} =
    (chrMethod, chrPath, chrBody >>= decode)

expectRight :: (Show e) => Either e a -> IO a
expectRight = \case
    Right value -> pure value
    Left err -> expectationFailure (show err) >> fail "unexpected Left"

transactionJson :: Text -> Value
transactionJson tx =
    object ["transaction" .= tx]

textJson :: Text -> BSL.ByteString
textJson =
    BSL.init . BSL.tail . encode

sampleTx :: Text
sampleTx = "83a400"

sampleWitness :: Text
sampleWitness = "82005820"

sampleBodyHash :: Text
sampleBodyHash =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sampleSigner :: Text
sampleSigner =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

sampleTxIn :: Text
sampleTxIn =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0"

sampleFeeQuote :: FeeQuote
sampleFeeQuote =
    FeeQuote
        { fqBodyHash = sampleBodyHash
        , fqRequiredFeeLovelace = 4_200_000
        , fqFeeAddress = "addr1fee"
        , fqTag = sampleBodyHash
        , fqInvalidHereafter = 123_456
        }

sampleEntry :: Entry
sampleEntry =
    Entry
        { eEntryId = sampleBodyHash
        , eTransaction = Just sampleTx
        , eRequiredSigners = [sampleSigner]
        , eWitnesses = []
        , eMissing = [sampleSigner]
        , eLiveness =
            Just
                Liveness
                    { lInputsUnspent = True
                    , lPhase1Ok = True
                    }
        , eInvalidHereafter = 123_456
        , eStatus = Collecting
        }

sampleEntryJson :: BSL.ByteString
sampleEntryJson =
    "{\
    \\"entry_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\
    \\"transaction\":\"83a400\",\
    \\"required_signers\":[\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\
    \\"witnesses\":[],\
    \\"missing\":[\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\
    \\"liveness\":{\"inputs_unspent\":true,\"phase1_ok\":true},\
    \\"invalid_hereafter\":123456,\
    \\"status\":\"collecting\"\
    \}"

sampleWitnessResultJson :: BSL.ByteString
sampleWitnessResultJson =
    "{\
    \\"witnesses\":[\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\
    \\"missing\":[],\
    \\"status\":\"ready\"\
    \}"
