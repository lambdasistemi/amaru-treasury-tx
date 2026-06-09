{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.GraphEffect
Description : Resolved graph-effect projection of an unsigned tx (#345)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Projects an unsigned Conway transaction onto the RDF lattice as a
structured @graph-effect@: its inputs and outputs resolved to treasury
@{scope, role}@ entities (cardano-ledger-rdf vocab) plus values and
projected datums, so a UI can render the spend→produce delta /before/
signing.

The projection is self-contained to the transaction: each input
@txid#ix@ outref is resolved against the indexed UTxO state (the same
'Amaru.Treasury.Api.Indexer.snapshotUtxosByTxIn' read the @\/v1\/tx@
detail uses), and each input\/output address is labelled with its
owning treasury via the same metadata resolver
('Amaru.Treasury.Api.History.outputScopeRoles') the resolved outputs
already use.

The carrier reuses 'TxDetailInput' (spend side) and 'TxDetailOutput'
(produce side), so the build-time graph-effect and the indexed
@\/v1\/tx@ detail share one resolved shape.
-}
module Amaru.Treasury.Api.GraphEffect
    ( GraphEffect (..)
    , graphEffect
    , graphEffectFromCborHex
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Plutus.Data qualified as PlutusData
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Node.Client.TxHistoryIndexer.Types
    ( TxSummaryInput (..)
    )

import Amaru.Treasury.Api.History
    ( inputFromSummary
    , outputScopeRoles
    , outputSwapProjection
    , renderInputAddress
    )
import Amaru.Treasury.Api.Types
    ( TxDetailInput (..)
    , TxDetailOutput (..)
    )
import Amaru.Treasury.Indexer.Decoder (decodeConwayTx)
import Amaru.Treasury.LedgerParse (txInToText)
import Amaru.Treasury.Metadata (TreasuryMetadata)
import Amaru.Treasury.Report.Accounting (valueSummary)

{- | The transaction projected onto the RDF lattice: its resolved
spends (inputs) and produces (outputs).

@spends@ are the input outrefs resolved against the indexed UTxO state
to their source @{scope, role}@ + value (reusing the @\/v1\/tx@
'TxDetailInput' shape; an input the indexer no longer holds keeps a
@resolved = False@ marker). @produces@ are the body outputs resolved to
their owning @{scope, role}@ + value + projected swap-order datum.
-}
data GraphEffect = GraphEffect
    { geSpends :: [TxDetailInput]
    , geProduces :: [TxDetailOutput]
    }
    deriving stock (Eq, Show)

instance ToJSON GraphEffect where
    toJSON g =
        object
            [ "spends" .= geSpends g
            , "produces" .= geProduces g
            ]

instance FromJSON GraphEffect where
    parseJSON =
        withObject "GraphEffect" $ \o ->
            GraphEffect
                <$> o .: "spends"
                <*> o .: "produces"

{- | Project an unsigned Conway transaction onto the RDF lattice.

@resolveUtxos@ resolves each input outref to its produced 'TxOut' from
the indexed UTxO state — in the API container this is
'Amaru.Treasury.Api.Indexer.snapshotUtxosByTxIn'. The body inputs are
taken in deterministic ascending order so a resolved 'TxOut' aligns
with its outref; outputs follow body order.
-}
graphEffect
    :: Maybe TreasuryMetadata
    -> (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> ConwayTx
    -> IO GraphEffect
graphEffect metadata resolveUtxos tx = do
    let roles = outputScopeRoles metadata
        inputs = tx ^. bodyTxL . inputsTxBodyL
        inputsAsc = Set.toAscList inputs
    utxos <- resolveUtxos inputs
    let spends =
            [ inputFromSummary roles (Map.lookup txIn utxos) (spendRow txIn)
            | txIn <- inputsAsc
            ]
        produces =
            zipWith
                (produceFromTxOut roles)
                [0 ..]
                (toList (tx ^. bodyTxL . outputsTxBodyL))
    pure GraphEffect{geSpends = spends, geProduces = produces}

{- | Project a transaction supplied as its unsigned Conway body hex —
the form the build response carries — resolving it via 'graphEffect'.
'Nothing' when the hex cannot be decoded back to a transaction.
-}
graphEffectFromCborHex
    :: Maybe TreasuryMetadata
    -> (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> Text
    -> IO (Maybe GraphEffect)
graphEffectFromCborHex metadata resolveUtxos cborHex =
    case decodeHex cborHex >>= decodeConwayTx of
        Just tx -> Just <$> graphEffect metadata resolveUtxos tx
        Nothing -> pure Nothing
  where
    decodeHex =
        either (const Nothing) Just . B16.decode . TE.encodeUtf8

{- | A minimal summary-input row carrying only the rendered @txid#ix@
outref 'inputFromSummary' echoes into 'tdiTxIn'; scope and value are
the decoder's unresolved placeholders the resolved path ignores.
-}
spendRow :: Ledger.TxIn -> TxSummaryInput
spendRow txIn =
    TxSummaryInput
        { tsiTxIn = TE.encodeUtf8 (txInToText txIn)
        , tsiScope = Nothing
        , tsiValue = ""
        }

{- | Resolve one produced output to its owning treasury @{scope, role}@
(via the same @roles@ map the inputs use), structured value, and
projected swap-order datum. Mirrors the resolved-output shape the
@\/v1\/tx@ detail produces.
-}
produceFromTxOut
    :: Map Text (Text, Text)
    -> Int
    -> TxOut ConwayEra
    -> TxDetailOutput
produceFromTxOut roles ix txOut =
    TxDetailOutput
        { tdoIndex = ix
        , tdoAddress = address
        , tdoScope = fst <$> resolved
        , tdoRole = snd <$> resolved
        , tdoValue = valueSummary (txOut ^. valueTxOutL)
        , tdoDatum = datumLabel (txOut ^. datumTxOutL)
        , tdoProjectedDatum = outputSwapProjection txOut
        }
  where
    address = renderInputAddress (txOut ^. addrTxOutL)
    resolved = Map.lookup address roles

{- | A short label for an output's datum, matching the indexer
decoder's @datumSummary@: the inline-datum marker or the hex datum
hash; 'Nothing' for an output with no datum.
-}
datumLabel :: PlutusData.Datum ConwayEra -> Maybe Text
datumLabel = \case
    PlutusData.NoDatum -> Nothing
    PlutusData.DatumHash h ->
        Just ("datumHash:" <> hexText (hashToBytes (extractHash h)))
    PlutusData.Datum _ -> Just "inlineDatum"

hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
