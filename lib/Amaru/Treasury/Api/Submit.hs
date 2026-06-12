{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.Submit
Description : Stateless submit preflight and broadcast helper
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Helper behind @POST \/v1\/submit@. It decodes the signed Conway
transaction, proves it has an Amaru treasury shape, runs the same
Phase-1 structural validation used by the build path against a sampled
chain context, and only then calls the injected broadcast action.
-}
module Amaru.Treasury.Api.Submit
    ( -- * Dependencies
      SubmitDependencies (..)

      -- * Helpers
    , submitTx
    , submitTxProduction
    , classifyTreasuryTx
    ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Ouroboros.Network.Magic (NetworkMagic)

import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (Provider)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , SubmitRequest (..)
    , SubmitResponse (..)
    )
import Amaru.Treasury.Build.Common (validateFinalPhase1)
import Amaru.Treasury.ChainContext
    ( networkFromMagic
    , withLiveContext
    )
import Amaru.Treasury.Indexer.Decoder
    ( decodeConwayTx
    , mkBlockTx
    , registryScopeMappingsFromMetadata
    , scopeAddressMappingsFromMetadata
    , treasuryDecodeTxWithInterest
    )
import Amaru.Treasury.Metadata (TreasuryMetadata)
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , renderSubmitOutcome
    , renderTxId
    , submitSignedTx
    )

{- | Submit helper dependencies.

Tests inject these to prove that classification and Phase-1 failures
return before broadcast. Production injects the real treasury
classifier, live Phase-1 preflight, and N2C submitter.
-}
data SubmitDependencies = SubmitDependencies
    { sdClassifyTreasury :: !(ByteString -> Either ApiError ())
    , sdPreflightPhase1 :: !(ConwayTx -> IO (Either ApiError ()))
    , sdBroadcast :: !(ByteString -> IO (Either ApiError Text))
    }

-- | Decode, preflight, and broadcast one submit request.
submitTx
    :: SubmitDependencies
    -> SubmitRequest
    -> IO (Either ApiError SubmitResponse)
submitTx deps (SubmitRequest cborHex) =
    case decodeSubmittedTx cborHex of
        Left err -> pure (Left err)
        Right (rawTx, tx) ->
            case sdClassifyTreasury deps rawTx of
                Left err -> pure (Left err)
                Right () -> do
                    preflight <- sdPreflightPhase1 deps tx
                    case preflight of
                        Left err -> pure (Left err)
                        Right () -> do
                            submitted <-
                                sdBroadcast deps (TE.encodeUtf8 cborHex)
                            pure (SubmitResponse <$> submitted)

-- | Production submit helper using metadata, live context, and N2C.
submitTxProduction
    :: NetworkMagic
    -> Provider IO
    -> TreasuryMetadata
    -> FilePath
    -> SubmitRequest
    -> IO (Either ApiError SubmitResponse)
submitTxProduction magic provider metadata socketPath =
    submitTx
        SubmitDependencies
            { sdClassifyTreasury =
                classifyTreasuryTx
                    (registryScopeMappingsFromMetadata metadata)
                    (scopeAddressMappingsFromMetadata metadata)
            , sdPreflightPhase1 =
                preflightPhase1 magic provider
            , sdBroadcast =
                broadcastSignedTx magic socketPath
            }

-- | Classify raw transaction bytes as an Amaru treasury transaction.
classifyTreasuryTx
    :: [(ByteString, ScopeId)]
    -> [(ByteString, ScopeId)]
    -> ByteString
    -> Either ApiError ()
classifyTreasuryTx registryMappings addressMappings rawTx =
    case treasuryDecodeTxWithInterest
        registryMappings
        addressMappings
        (SlotNo 0)
        (mkBlockTx rawTx) of
        Just (_ : _) -> Right ()
        _ ->
            Left
                ApiError
                    { aeMessage =
                        "transaction is not an Amaru treasury transaction"
                    , aeField = Just "cborHex"
                    }

decodeSubmittedTx :: Text -> Either ApiError (ByteString, ConwayTx)
decodeSubmittedTx cborHex = do
    rawTx <-
        first invalidHex $
            B16.decode (TE.encodeUtf8 cborHex)
    tx <-
        maybe
            ( Left
                ApiError
                    { aeMessage =
                        "submit transaction CBOR is not a Conway transaction"
                    , aeField = Just "cborHex"
                    }
            )
            Right
            (decodeConwayTx rawTx)
    pure (rawTx, tx)

invalidHex :: String -> ApiError
invalidHex err =
    ApiError
        { aeMessage =
            "submit transaction CBOR hex is not valid base16: "
                <> T.pack err
        , aeField = Just "cborHex"
        }

preflightPhase1
    :: NetworkMagic
    -> Provider IO
    -> ConwayTx
    -> IO (Either ApiError ())
preflightPhase1 magic provider tx =
    withLiveContext
        (networkFromMagic magic)
        provider
        (neededTxIns tx)
        $ \ctx ->
            pure $
                first phase1Error $
                    validateFinalPhase1 ctx tx

phase1Error :: Text -> ApiError
phase1Error msg =
    ApiError
        { aeMessage = msg
        , aeField = Just "cborHex"
        }

neededTxIns :: ConwayTx -> Set.Set TxIn
neededTxIns tx =
    Set.unions
        [ body ^. inputsTxBodyL
        , body ^. referenceInputsTxBodyL
        , body ^. collateralInputsTxBodyL
        ]
  where
    body = tx ^. bodyTxL

broadcastSignedTx
    :: NetworkMagic
    -> FilePath
    -> ByteString
    -> IO (Either ApiError Text)
broadcastSignedTx magic socketPath cborHex = do
    outcome <- submitSignedTx magic socketPath cborHex
    pure $ case outcome of
        SubmitAccepted txId ->
            Right (renderTxId txId)
        SubmitRejected _ ->
            Left (submitOutcomeError outcome)
        SubmitDecodeFailed _ ->
            Left (submitOutcomeError outcome)

submitOutcomeError :: SubmitOutcome -> ApiError
submitOutcomeError outcome =
    ApiError
        { aeMessage = renderSubmitOutcome outcome
        , aeField = Just "cborHex"
        }
