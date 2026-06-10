{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.Api.Proofs
Description : SPARQL proof suite over the built-tx graph (#358)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Runs a fixed catalog of three SPARQL proof queries over the RDF
lattice of a freshly built unsigned transaction — the
'Amaru.Treasury.Api.Ttl.buildTxLatticeResolved' Turtle, which
carries the @cq-rdf body@ graph, the metadata entity overlay,
and the resolved value of every spent input:

* @value-conservation@ — per asset, consumed (resolved inputs +
  withdrawals) versus produced (outputs, plus fee for ada).
* @recipient-resolution@ — each output address resolved to its
  treasury @{scope, role}@ entity, or @external@.
* @datum-redeemer@ — the datum and redeemer artifacts the body
  graph carries, with hashes and raw Plutus Data hex.

Queries are embedded at compile time and run through the same
Apache Jena @arq@ runner the history surface uses
('Amaru.Treasury.History.Sparql.runArqTable'); callers select
nothing — the suite is fixed, so the HTTP surface never becomes
a SPARQL console.
-}
module Amaru.Treasury.Api.Proofs
    ( ProofResult (..)
    , runBuildProofs
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn qualified as Ledger

import Amaru.Treasury.Api.Ttl (buildTxLatticeResolved)
import Amaru.Treasury.History.Sparql (runArqTable)
import Amaru.Treasury.Metadata (TreasuryMetadata)

{- | One named proof: the SPARQL result table of one fixed query
over the built-tx lattice. JSON shape is
@{name, columns, rows}@.
-}
data ProofResult = ProofResult
    { prName :: !Text
    -- ^ Stable proof name, e.g. @value-conservation@.
    , prColumns :: ![Text]
    -- ^ SPARQL variable names without the leading @?@.
    , prRows :: ![[Text]]
    -- ^ Result cells in 'prColumns' order, one inner list
    --   per row.
    }
    deriving stock (Eq, Show)

instance ToJSON ProofResult where
    toJSON p =
        object
            [ "name" .= prName p
            , "columns" .= prColumns p
            , "rows" .= prRows p
            ]

instance FromJSON ProofResult where
    parseJSON =
        withObject "ProofResult" $ \o ->
            ProofResult
                <$> o .: "name"
                <*> o .: "columns"
                <*> o .: "rows"

-- | The fixed proof catalog, in response order.
proofQueries :: [(Text, ByteString)]
proofQueries =
    [
        ( "value-conservation"
        , $( embedFile
                "lib/Amaru/Treasury/Api/queries/value-conservation.rq"
           )
        )
    ,
        ( "recipient-resolution"
        , $( embedFile
                "lib/Amaru/Treasury/Api/queries/recipient-resolution.rq"
           )
        )
    ,
        ( "datum-redeemer"
        , $( embedFile
                "lib/Amaru/Treasury/Api/queries/datum-redeemer.rq"
           )
        )
    ]

{- | Run the three proof queries over one unsigned transaction,
supplied as the cbor hex its build response carries.

Builds the resolved lattice once
('Amaru.Treasury.Api.Ttl.buildTxLatticeResolved', with
@resolveUtxos@ supplying the spent-input 'TxOut's), then runs
each embedded query through Apache Jena @arq@. Best-effort like
the lattice itself: 'Nothing' when the hex does not decode or
any @cq-rdf@\/@arq@ step fails — the proofs decorate the build
response and must never fail it.
-}
runBuildProofs
    :: Maybe TreasuryMetadata
    -> (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> Text
    -- ^ Unsigned tx cbor hex, as carried by the build response.
    -> IO (Maybe [ProofResult])
runBuildProofs metadata resolveUtxos cborHex = do
    lattice <-
        buildTxLatticeResolved metadata resolveUtxos cborHex
    case lattice of
        Nothing -> pure Nothing
        Just ttl -> do
            let ttlBytes = TE.encodeUtf8 ttl
            results <- traverse (runProof ttlBytes) proofQueries
            pure (sequence results)

runProof
    :: ByteString
    -> (Text, ByteString)
    -> IO (Maybe ProofResult)
runProof ttl (name, query) = do
    result <- runArqTable query ttl
    pure $ case result of
        Left _ -> Nothing
        Right (columns, rows) ->
            Just
                ProofResult
                    { prName = name
                    , prColumns = columns
                    , prRows = rows
                    }
