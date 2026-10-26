{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Backend.Indexer
Description : UTxO reads served by the treasury API indexer (#522)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Both ends of @POST \/v1\/utxos@:

* the wire carriers and their Conway @TxOut@ CBOR codec;
* 'answerUtxoQuery', the server side, run by
  @amaru-treasury-tx-api@ over its indexer-backed provider;
* 'withUtxoSource', the client side, which replaces every UTxO
  query of a live 'Provider' — direct and acquired-handle — with
  a 'UtxoSource', leaving all other ledger queries on the live
  provider. 'httpUtxoSource' is the 'UtxoSource' that calls the
  API.

The CLI uses it so wizards never issue N2C @GetUTxOByAddress@: on
mainnet that query outlives the client's local-state-query timeout.
A failed or undecodable answer throws 'IndexerQueryError'; there is
no fallback to node UTxO queries.
-}
module Amaru.Treasury.Backend.Indexer
    ( -- * Wire carriers
      UtxoQueryRequest (..)
    , UtxoQueryEntry (..)
    , UtxoQueryResponse (..)
    , encodeUtxoEntry
    , decodeUtxoEntry

      -- * Server side
    , answerUtxoQuery

      -- * Client side
    , UtxoSource (..)
    , IndexerQueryError (..)
    , withUtxoSource
    , tracedUtxoSource
    , utxoSourceFromTransport
    , httpUtxoSource
    , httpUtxoTransport
    ) where

import Control.Exception
    ( Exception (..)
    , SomeException
    , throwIO
    , try
    )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecode'
    , encode
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Types (Parser)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
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
import Network.HTTP.Types.Header (hAccept, hContentType)
import Network.HTTP.Types.Method (methodPost)
import Network.HTTP.Types.Status (statusCode)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.Binary (decodeFull', serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider
    ( Provider (..)
    , QueryHandleBackend (..)
    , mkQueryHandle
    )
import Cardano.Node.Client.Provider qualified as Provider
import Control.Tracer (Tracer)

import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , parseTxIn
    , renderAddrBech32
    )
import Amaru.Treasury.Trace (Severity (..), traced)
import Amaru.Treasury.Tx.SwapWizard (txInToText)

-- ---------------------------------------------------------------------------
-- Wire carriers

{- | Body of @POST \/v1\/utxos@: either bech32 addresses or
@\<txid hex\>#\<ix\>@ inputs.
-}
data UtxoQueryRequest
    = UtxoQueryByAddresses ![Text]
    | UtxoQueryByTxIns ![Text]
    deriving stock (Eq, Show)

instance ToJSON UtxoQueryRequest where
    toJSON = \case
        UtxoQueryByAddresses addrs -> object ["addresses" .= addrs]
        UtxoQueryByTxIns txins -> object ["txins" .= txins]

instance FromJSON UtxoQueryRequest where
    parseJSON = withObject "UtxoQueryRequest" $ \o -> do
        addrs <- o .:? "addresses" :: Parser (Maybe [Text])
        txins <- o .:? "txins" :: Parser (Maybe [Text])
        case (addrs, txins) of
            (Just as, Nothing) -> pure (UtxoQueryByAddresses as)
            (Nothing, Just ts) -> pure (UtxoQueryByTxIns ts)
            _ ->
                fail
                    "expected exactly one of \"addresses\" or \"txins\""

-- | One unspent output: its input and the Conway @TxOut@ CBOR.
data UtxoQueryEntry = UtxoQueryEntry
    { uqeTxIn :: !Text
    , uqeTxOutCborHex :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON UtxoQueryEntry where
    toJSON e =
        object
            [ "txIn" .= uqeTxIn e
            , "txOutCborHex" .= uqeTxOutCborHex e
            ]

instance FromJSON UtxoQueryEntry where
    parseJSON = withObject "UtxoQueryEntry" $ \o ->
        UtxoQueryEntry <$> o .: "txIn" <*> o .: "txOutCborHex"

-- | Answer of @POST \/v1\/utxos@.
newtype UtxoQueryResponse = UtxoQueryResponse
    { uqrUtxos :: [UtxoQueryEntry]
    }
    deriving stock (Eq, Show)

instance ToJSON UtxoQueryResponse where
    toJSON r = object ["utxos" .= uqrUtxos r]

instance FromJSON UtxoQueryResponse where
    parseJSON = withObject "UtxoQueryResponse" $ \o ->
        UtxoQueryResponse <$> o .: "utxos"

-- | Encode one UTxO for the wire.
encodeUtxoEntry :: (TxIn, TxOut ConwayEra) -> UtxoQueryEntry
encodeUtxoEntry (txIn, txOut) =
    UtxoQueryEntry
        { uqeTxIn = txInToText txIn
        , uqeTxOutCborHex =
            TE.decodeUtf8
                ( B16.encode
                    (serialize' (eraProtVerLow @ConwayEra) txOut)
                )
        }

-- | Decode one wire UTxO. Inverse of 'encodeUtxoEntry'.
decodeUtxoEntry
    :: UtxoQueryEntry -> Either String (TxIn, TxOut ConwayEra)
decodeUtxoEntry e = do
    txIn <- parseTxIn (uqeTxIn e)
    raw <- B16.decode (TE.encodeUtf8 (uqeTxOutCborHex e))
    txOut <-
        either
            (Left . ("txOut cbor: " <>) . show)
            Right
            (decodeFull' (eraProtVerLow @ConwayEra) raw)
    pure (txIn, txOut)

-- ---------------------------------------------------------------------------
-- Server side

{- | Answer a request from a provider's UTxO queries. A malformed
address or input is a 'Left' naming it; the caller maps it to
HTTP 400.
-}
answerUtxoQuery
    :: Provider IO
    -> UtxoQueryRequest
    -> IO (Either Text UtxoQueryResponse)
answerUtxoQuery provider = \case
    UtxoQueryByAddresses raw ->
        case traverse (parsed "address" parseAddr) raw of
            Left err -> pure (Left err)
            Right addrs -> do
                utxos <- concat <$> traverse (queryUTxOs provider) addrs
                pure (Right (respond utxos))
    UtxoQueryByTxIns raw ->
        case traverse (parsed "txin" parseTxIn) raw of
            Left err -> pure (Left err)
            Right txins -> do
                found <- queryUTxOByTxIn provider (Set.fromList txins)
                pure (Right (respond (Map.toList found)))
  where
    respond = UtxoQueryResponse . fmap encodeUtxoEntry
    parsed what parse t =
        either
            (\e -> Left (what <> " " <> t <> ": " <> T.pack e))
            Right
            (parse t)

-- ---------------------------------------------------------------------------
-- Client side

-- | Where a wrapped provider reads its UTxOs from.
data UtxoSource = UtxoSource
    { usQueryAddresses :: [Addr] -> IO [(TxIn, TxOut ConwayEra)]
    -- ^ UTxOs at any of the given addresses.
    , usQueryTxIns :: Set TxIn -> IO (Map TxIn (TxOut ConwayEra))
    -- ^ Unspent outputs among the given inputs.
    }

-- | Failure of an indexer-backed UTxO read.
data IndexerQueryError
    = IndexerTransportFailed !Text
    | IndexerHttpStatus !Int !Text
    | IndexerDecodeFailed !Text
    deriving stock (Eq, Show)

instance Exception IndexerQueryError where
    displayException = \case
        IndexerTransportFailed msg ->
            "indexer: request failed: " <> T.unpack msg
        IndexerHttpStatus code body ->
            "indexer: HTTP "
                <> show code
                <> ": "
                <> T.unpack body
        IndexerDecodeFailed msg ->
            "indexer: undecodable answer: " <> T.unpack msg

{- | Replace every UTxO query of a live provider — the direct
'queryUTxOs' / 'queryUTxOByTxIn' and the acquired handle's
'Provider.queryUTxOsH' / 'Provider.queryUTxOsAtH' /
'Provider.queryUTxOByTxInH' — with the source. Every other field,
including the rest of the acquired handle, stays the live
provider's.
-}
withUtxoSource :: UtxoSource -> Provider IO -> Provider IO
withUtxoSource source live =
    live
        { withAcquired = \callback ->
            Provider.withAcquired live $ \handle ->
                callback $
                    mkQueryHandle
                        QueryHandleBackend
                            { backendQueryUTxOs = byAddress
                            , backendQueryUTxOsAt = byAddresses
                            , backendQueryUTxOByTxIn = usQueryTxIns source
                            , backendQueryProtocolParams =
                                Provider.queryProtocolParamsH handle
                            , backendQueryLedgerSnapshot =
                                Provider.queryLedgerSnapshotH handle
                            , backendQueryStakeRewards =
                                Provider.queryStakeRewardsH handle
                            , backendQueryRewardAccounts =
                                Provider.queryRewardAccountsH handle
                            , backendQueryVoteDelegatees =
                                Provider.queryVoteDelegateesH handle
                            , backendQueryTreasury =
                                Provider.queryTreasuryH handle
                            , backendQueryGovernanceState =
                                Provider.queryGovernanceStateH handle
                            , backendEvaluateTx =
                                Provider.evaluateTxH handle
                            , backendPosixMsToSlot =
                                Provider.posixMsToSlotH handle
                            , backendPosixMsCeilSlot =
                                Provider.posixMsCeilSlotH handle
                            }
        , queryUTxOs = byAddress
        , queryUTxOByTxIn = usQueryTxIns source
        }
  where
    byAddress addr = usQueryAddresses source [addr]
    byAddresses addrs = do
        utxos <- usQueryAddresses source (Set.toList addrs)
        pure $
            Map.fromListWith
                (flip (<>))
                ( [(a, []) | a <- Set.toList addrs]
                    <> [ (a, [utxo])
                       | utxo@(_, txOut) <- utxos
                       , let a = txOut ^. addrTxOutL
                       , a `Set.member` addrs
                       ]
                )

-- | Trace each source lookup as @indexer.*@ start / ok / failed.
tracedUtxoSource
    :: Tracer IO (Severity, Text) -> UtxoSource -> UtxoSource
tracedUtxoSource tr source =
    UtxoSource
        { usQueryAddresses =
            traced tr Info "indexer.queryUTxOs"
                . usQueryAddresses source
        , usQueryTxIns =
            traced tr Info "indexer.queryUTxOByTxIn"
                . usQueryTxIns source
        }

{- | Build a source from a request/response transport, decoding
every entry. Any transport error or undecodable entry throws
'IndexerQueryError'.
-}
utxoSourceFromTransport
    :: ( UtxoQueryRequest
         -> IO (Either IndexerQueryError UtxoQueryResponse)
       )
    -> UtxoSource
utxoSourceFromTransport transport =
    UtxoSource
        { usQueryAddresses = \addrs ->
            run (UtxoQueryByAddresses (renderAddrBech32 <$> addrs))
        , usQueryTxIns = \txins ->
            Map.fromList
                <$> run
                    (UtxoQueryByTxIns (txInToText <$> Set.toList txins))
        }
  where
    run req = do
        answer <- transport req >>= either throwIO pure
        either
            (throwIO . IndexerDecodeFailed . T.pack)
            pure
            (traverse decodeUtxoEntry (uqrUtxos answer))

{- | The API-backed source: @POST \<base url\>\/v1\/utxos@, e.g.
@http:\/\/127.0.0.1:8080@.
-}
httpUtxoSource :: Text -> UtxoSource
httpUtxoSource = utxoSourceFromTransport . httpUtxoTransport

-- | One @POST \/v1\/utxos@ round trip.
httpUtxoTransport
    :: Text
    -> UtxoQueryRequest
    -> IO (Either IndexerQueryError UtxoQueryResponse)
httpUtxoTransport baseUrl req = do
    outcome <- try @SomeException $ do
        initial <- parseRequest (T.unpack url)
        httpLBS
            initial
                { method = methodPost
                , requestBody = RequestBodyLBS (encode req)
                , requestHeaders =
                    [ (hContentType, "application/json")
                    , (hAccept, "application/json")
                    ]
                , responseTimeout = responseTimeoutMicro 120_000_000
                }
    pure $ case outcome of
        Left err ->
            Left
                ( IndexerTransportFailed
                    (url <> ": " <> T.pack (displayException err))
                )
        Right response
            | code /= 200 ->
                Left
                    ( IndexerHttpStatus
                        code
                        ( TE.decodeUtf8Lenient
                            (BSL.toStrict (getResponseBody response))
                        )
                    )
            | otherwise ->
                either
                    (Left . IndexerDecodeFailed . T.pack)
                    Right
                    (eitherDecode' (getResponseBody response))
          where
            code = statusCode (getResponseStatus response)
  where
    url = T.dropWhileEnd (== '/') baseUrl <> "/v1/utxos"
