{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.Introspect
Description : Stateless unsigned transaction introspection endpoint
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helper behind @POST \/v1\/tx\/introspect@. It decodes an
unsigned Conway transaction body and returns only facts derivable from
the submitted bytes: tx id, required signer key hashes, TTL, and an
optional best-effort scope label.
-}
module Amaru.Treasury.Api.Introspect
    ( introspectTx
    ) where

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (vldtTxBodyL)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Bifunctor (first)
import Data.Set qualified as Set
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Lens.Micro ((^.))

import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , IntrospectRequest (..)
    , IntrospectResponse (..)
    )
import Amaru.Treasury.Build.Common (strictMaybe, txIdText)
import Amaru.Treasury.Metadata (TreasuryMetadata)
import Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , TxWitnessError
    , decodeWitnessTransaction
    , renderGuardKeyHash
    , renderTxWitnessError
    , witnessTransactionFacts
    )

{- | Decode and summarize an unsigned Conway transaction.

The optional metadata argument is reserved for best-effort future scope
resolution. The current implementation intentionally performs no IO and
does not consult any server-side index or provider.
-}
introspectTx
    :: Maybe TreasuryMetadata
    -> IntrospectRequest
    -> Either ApiError IntrospectResponse
introspectTx _metadata (IntrospectRequest cborHex) = do
    tx <-
        first decodeError $
            decodeWitnessTransaction (TE.encodeUtf8 cborHex)
    let facts = witnessTransactionFacts tx
    pure
        IntrospectResponse
            { irTxid = txIdText tx
            , irRequiredSigners =
                renderGuardKeyHash
                    <$> Set.toAscList (tsfRequiredSigners facts)
            , irInvalidHereafter = txInvalidHereafter tx
            , irScope = Nothing
            }

txInvalidHereafter :: ConwayTx -> Maybe Word64
txInvalidHereafter tx =
    case tx ^. bodyTxL . vldtTxBodyL of
        ValidityInterval _ to -> slotNo <$> strictMaybe to

slotNo :: SlotNo -> Word64
slotNo (SlotNo slot) = slot

decodeError :: TxWitnessError -> ApiError
decodeError err =
    ApiError
        { aeMessage =
            "failed to decode unsigned transaction: "
                <> renderTxWitnessError err
        , aeField = Just "cborHex"
        }
