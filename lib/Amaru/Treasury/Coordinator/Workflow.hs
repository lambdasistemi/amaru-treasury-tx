{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Coordinator.Workflow
Description : Effect-injected coordinator witness workflow
License     : Apache-2.0

This module wires the ordered @cardano-multisig@ coordinator flow
without owning HTTP or node IO. Callers inject the coordinator client
actions and the fee-payment boundary, while the workflow keeps the
transaction-critical checks local: it verifies the coordinator's body
hash quote, creates the requester pre-witness, publishes the partially
witnessed transaction, uploads owner witnesses, and submits the entry.
-}
module Amaru.Treasury.Coordinator.Workflow
    ( -- * Request and configuration
      CoordinationRequest (..)
    , WorkflowConfig (..)

      -- * Injected effects
    , CoordinationEffects (..)

      -- * Result and errors
    , CoordinationResult (..)
    , CoordinationError (..)

      -- * Runner
    , runCoordinationWorkflow
    ) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Coordinator.Client
    ( CoordinatorClientError
    , Entry (..)
    , EntryStatus
    , FeeQuote (..)
    , FeeQuoteRequest (..)
    , FeeStatus (..)
    , PublishRequest (..)
    , Receipt
    , WitnessRequest (..)
    , WitnessResult (..)
    )
import Amaru.Treasury.Tx.AttachWitness
    ( AttachError
    , attachWitnesses
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    )
import Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , TxWitnessError
    , createWitness
    , decodeWitnessTransaction
    , witnessTransactionFacts
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    )

-- | Inputs required to coordinate witness collection for one tx.
data CoordinationRequest = CoordinationRequest
    { crUnsignedTx :: !Text
    -- ^ Unsigned Conway transaction CBOR hex.
    , crRequester :: !VaultIdentity
    -- ^ Vault identity that pays and pre-witnesses the tx.
    , crOwners :: !(NonEmpty VaultIdentity)
    -- ^ Owner identities whose raw vkey witnesses are uploaded.
    }

-- | Retry policy for coordinator polling.
newtype WorkflowConfig = WorkflowConfig
    { wcFeeStatusMaxPolls :: Int
    -- ^ Maximum number of @GET /fee-status@ attempts.
    }
    deriving stock (Eq, Show)

-- | Effect boundary for coordinator and fee-payment actions.
data CoordinationEffects m = CoordinationEffects
    { cweQuoteFee
        :: FeeQuoteRequest
        -> m (Either CoordinatorClientError FeeQuote)
    -- ^ Request @POST /v1/fee-quote@.
    , cwePayFee
        :: FeeQuote
        -> m (Either Text (Maybe Text))
    -- ^ Pay the returned fee quote, returning an optional tx-in.
    , cweGetFeeStatus
        :: Text
        -> m (Either CoordinatorClientError FeeStatus)
    -- ^ Poll @GET /v1/fee-status/{body_hash}@.
    , cwePublishEntry
        :: PublishRequest
        -> m (Either CoordinatorClientError Entry)
    -- ^ Publish the partially witnessed transaction.
    , cweAddWitness
        :: Text
        -> WitnessRequest
        -> m (Either CoordinatorClientError WitnessResult)
    -- ^ Upload one owner witness to the entry.
    , cweSubmitEntry
        :: Text
        -> m (Either CoordinatorClientError Receipt)
    -- ^ Submit the completed coordinator entry.
    }

-- | Summary returned after a successful coordinator submission.
data CoordinationResult = CoordinationResult
    { cwrEntryId :: !Text
    , cwrUploadedWitnesses :: ![Text]
    , cwrReceipt :: !Receipt
    , cwrFinalStatus :: !EntryStatus
    , cwrFeePayment :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

-- | Typed workflow failure before CLI rendering.
data CoordinationError
    = CoordinationDecodeFailed !Text
    | CoordinationWitnessFailed !TxWitnessError
    | CoordinationAttachFailed !AttachError
    | CoordinationClientFailure !CoordinatorClientError
    | CoordinationFeePaymentFailed !Text
    | CoordinationBodyHashMismatch !Text !Text
    | CoordinationFeeNotPaid !Text !Int !FeeStatus
    deriving stock (Eq, Show)

-- | Run the ordered coordinator witness workflow.
runCoordinationWorkflow
    :: (Monad m)
    => WorkflowConfig
    -> CoordinationEffects m
    -> CoordinationRequest
    -> m (Either CoordinationError CoordinationResult)
runCoordinationWorkflow config effects request@CoordinationRequest{..} =
    case decodeLocalTransaction crUnsignedTx of
        Left err -> pure (Left err)
        Right tx -> do
            let facts = witnessTransactionFacts tx
                localBodyHash = tsfBodyHashHex facts
            quoteResult <-
                cweQuoteFee effects (FeeQuoteRequest crUnsignedTx)
            case quoteResult of
                Left err -> pure (Left (CoordinationClientFailure err))
                Right quote
                    | fqBodyHash quote /= localBodyHash ->
                        pure $
                            Left $
                                CoordinationBodyHashMismatch
                                    localBodyHash
                                    (fqBodyHash quote)
                    | otherwise ->
                        continueWithQuote
                            config
                            effects
                            request
                            tx
                            localBodyHash
                            quote

continueWithQuote
    :: (Monad m)
    => WorkflowConfig
    -> CoordinationEffects m
    -> CoordinationRequest
    -> ConwayTx
    -> Text
    -> FeeQuote
    -> m (Either CoordinationError CoordinationResult)
continueWithQuote config effects CoordinationRequest{..} tx localBodyHash quote =
    case requesterPublishHex crRequester tx of
        Left err -> pure (Left err)
        Right partialTxHex -> do
            feeResult <- cwePayFee effects quote
            case feeResult of
                Left err ->
                    pure (Left (CoordinationFeePaymentFailed err))
                Right feePayment -> do
                    statusResult <-
                        pollFeeStatus
                            config
                            effects
                            localBodyHash
                    case statusResult of
                        Left err -> pure (Left err)
                        Right _status -> do
                            publishResult <-
                                cwePublishEntry
                                    effects
                                    PublishRequest
                                        { prTransaction = partialTxHex
                                        , prFeePayment = feePayment
                                        }
                            case publishResult of
                                Left err ->
                                    pure
                                        (Left (CoordinationClientFailure err))
                                Right entry ->
                                    uploadOwnersAndSubmit
                                        effects
                                        crOwners
                                        tx
                                        entry
                                        feePayment

requesterPublishHex
    :: VaultIdentity -> ConwayTx -> Either CoordinationError Text
requesterPublishHex requester tx = do
    witnessHex <- mapWitnessError (createWitness requester tx)
    witness <- mapAttachError (decodeVKeyWitnessHex 1 witnessHex)
    pure $
        TE.decodeUtf8 $
            encodeSignedTxHex $
                attachWitnesses (Set.singleton witness) tx

pollFeeStatus
    :: (Monad m)
    => WorkflowConfig
    -> CoordinationEffects m
    -> Text
    -> m (Either CoordinationError FeeStatus)
pollFeeStatus WorkflowConfig{wcFeeStatusMaxPolls} effects bodyHash =
    go 1 Nothing
  where
    maxPolls = max 0 wcFeeStatusMaxPolls
    go attempt lastStatus
        | attempt > maxPolls =
            pure $
                Left $
                    CoordinationFeeNotPaid
                        bodyHash
                        maxPolls
                        (fallbackStatus lastStatus)
        | otherwise = do
            result <- cweGetFeeStatus effects bodyHash
            case result of
                Left err ->
                    pure (Left (CoordinationClientFailure err))
                Right status
                    | fsReadyToPublish status -> pure (Right status)
                    | otherwise -> go (attempt + 1) (Just status)
    fallbackStatus =
        fromMaybe
            FeeStatus
                { fsObserved = False
                , fsConfirmed = False
                , fsSufficient = False
                , fsReadyToPublish = False
                , fsPaidLovelace = 0
                , fsRequiredLovelace = 0
                , fsConfirmations = 0
                , fsReason = Nothing
                }

uploadOwnersAndSubmit
    :: (Monad m)
    => CoordinationEffects m
    -> NonEmpty VaultIdentity
    -> ConwayTx
    -> Entry
    -> Maybe Text
    -> m (Either CoordinationError CoordinationResult)
uploadOwnersAndSubmit effects owners tx entry feePayment = do
    uploadResult <-
        uploadOwnerWitnesses effects (eEntryId entry) owners tx
    case uploadResult of
        Left err -> pure (Left err)
        Right (witnesses, finalStatus) -> do
            submitResult <- cweSubmitEntry effects (eEntryId entry)
            pure $ do
                receipt <-
                    either
                        (Left . CoordinationClientFailure)
                        Right
                        submitResult
                Right
                    CoordinationResult
                        { cwrEntryId = eEntryId entry
                        , cwrUploadedWitnesses = witnesses
                        , cwrReceipt = receipt
                        , cwrFinalStatus = finalStatus
                        , cwrFeePayment = feePayment
                        }

uploadOwnerWitnesses
    :: (Monad m)
    => CoordinationEffects m
    -> Text
    -> NonEmpty VaultIdentity
    -> ConwayTx
    -> m (Either CoordinationError ([Text], EntryStatus))
uploadOwnerWitnesses effects entryId owners tx =
    go [] Nothing (NE.toList owners)
  where
    go uploaded finalStatus = \case
        [] ->
            case finalStatus of
                Nothing ->
                    pure
                        ( Left
                            ( CoordinationDecodeFailed
                                "owner witness list unexpectedly empty"
                            )
                        )
                Just status ->
                    pure (Right (uploaded, status))
        owner : rest ->
            case ownerWitnessText owner tx of
                Left err -> pure (Left err)
                Right witnessText -> do
                    result <-
                        cweAddWitness
                            effects
                            entryId
                            (WitnessRequest witnessText)
                    case result of
                        Left err ->
                            pure (Left (CoordinationClientFailure err))
                        Right witnessResult ->
                            go
                                (uploaded <> [witnessText])
                                (Just (wrStatus witnessResult))
                                rest

ownerWitnessText
    :: VaultIdentity -> ConwayTx -> Either CoordinationError Text
ownerWitnessText owner tx =
    TE.decodeUtf8 <$> mapWitnessError (createWitness owner tx)

decodeLocalTransaction :: Text -> Either CoordinationError ConwayTx
decodeLocalTransaction txHex =
    mapWitnessError (decodeWitnessTransaction (TE.encodeUtf8 txHex))

mapWitnessError
    :: Either TxWitnessError a -> Either CoordinationError a
mapWitnessError =
    either (Left . CoordinationWitnessFailed) Right

mapAttachError
    :: Either AttachError a -> Either CoordinationError a
mapAttachError =
    either (Left . CoordinationAttachFailed) Right
