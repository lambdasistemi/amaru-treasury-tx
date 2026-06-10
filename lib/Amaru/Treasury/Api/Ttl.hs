{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.Ttl
Description : RDF Turtle lattice for a freshly built unsigned tx (#357)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Projects an unsigned transaction (as the cbor hex a @POST
\/v1\/build\/*@ response carries) onto the same RDF lattice the
history surface builds: the shared Turtle prefix block, the
treasury entity overlay from verified metadata, and the ledger
body triples emitted by the upstream @cq-rdf@ executable.

Mirrors 'Amaru.Treasury.History.Sparql.buildHistoryLattice' for
a single not-yet-submitted transaction: same prefix vocabulary,
same 'metadataEntityTriples' overlay, same @cq-rdf body@
emitter shelled out against a temp file.

The @cq-rdf body@ graph references each spent input only as a
@txid#ix@ outref; 'buildTxLatticeResolved' additionally emits
the resolved source UTxO of every spent input — via
'resolvedInputTurtle', under the same @urn:cardano:utxo:@ IRI
scheme and value vocabulary the body graph uses for outputs —
so lattice queries can reason about consumed values (#358).
-}
module Amaru.Treasury.Api.Ttl
    ( buildTxLattice
    , buildTxLatticeResolved
    , resolvedInputTurtle
    ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn qualified as Ledger

import Amaru.Treasury.Api.History (renderInputAddress)
import Amaru.Treasury.History.Sparql
    ( metadataEntityTriples
    , turtlePrefixLines
    )
import Amaru.Treasury.Indexer.Decoder (decodeConwayTx)
import Amaru.Treasury.LedgerParse (txInToText)
import Amaru.Treasury.Metadata (TreasuryMetadata)
import Amaru.Treasury.Registry.Derive (scriptHashToHex)

{- | Emit the RDF Turtle lattice of one unsigned transaction:
prefix block, metadata entity overlay, then the @cq-rdf body@
triples of the transaction itself.

'Nothing' when the hex does not decode or @cq-rdf@ is
unavailable or exits non-zero — the TTL is a best-effort
projection (like the build-time graph-effect) and must never
fail the build response that carries it.
-}
buildTxLattice
    :: Maybe TreasuryMetadata
    -> Text
    -- ^ Unsigned tx cbor hex, as carried by the build response.
    -> IO (Maybe Text)
buildTxLattice metadata cborHex =
    case decodeHex cborHex of
        Nothing -> pure Nothing
        Just bytes ->
            withSystemTempDirectory "amaru-build-ttl" $ \dir -> do
                let txPath = dir </> "tx.cbor"
                result <-
                    try $ do
                        BS.writeFile txPath bytes
                        readProcessWithExitCode
                            "cq-rdf"
                            ["body", txPath]
                            ""
                pure $ case result of
                    Left (_ :: IOException) -> Nothing
                    Right (ExitSuccess, out, _) ->
                        Just (assemble (T.pack out))
                    Right (ExitFailure _, _, _) -> Nothing
  where
    assemble body =
        T.intercalate
            "\n"
            [ T.unlines turtlePrefixLines
            , TE.decodeUtf8 (metadataEntityTriples metadata)
            , body
            ]

{- | 'buildTxLattice' enriched with the resolved source UTxO of
every spent input: the tx body names its inputs by @txid#ix@
outref only, so @resolveUtxos@ (in the API container the same
'Amaru.Treasury.Api.Indexer.snapshotUtxosByTxIn' read the
graph-effect uses) supplies the consumed 'TxOut's, which
'resolvedInputTurtle' appends in the body-graph vocabulary.

Same best-effort contract as 'buildTxLattice': 'Nothing' when
the hex does not decode or @cq-rdf@ fails. Inputs the resolver
no longer holds are simply absent from the enrichment — a
value-conservation query then reports them as unbalanced
rather than failing.
-}
buildTxLatticeResolved
    :: Maybe TreasuryMetadata
    -> (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> Text
    -- ^ Unsigned tx cbor hex, as carried by the build response.
    -> IO (Maybe Text)
buildTxLatticeResolved metadata resolveUtxos cborHex = do
    base <- buildTxLattice metadata cborHex
    case (base, decodeHex cborHex >>= decodeConwayTx) of
        (Just ttl, Just tx) -> do
            utxos <-
                resolveUtxos (tx ^. bodyTxL . inputsTxBodyL)
            pure (Just (ttl <> "\n" <> resolvedInputTurtle utxos))
        _ -> pure Nothing

{- | Emit the resolved source UTxO of each spent input as Turtle
in the @cq-rdf body@ output vocabulary: one
@\<urn:cardano:utxo:txid:ix\> a cardano:Output@ node per input
carrying @cardano:atAddress@ \/ @cardano:bech32@,
@cardano:lovelace@, and — for multi-asset values — the same
@cardano:hasAssetValue@ RDF list of @cardano:Asset@ entries
keyed by @urn:cardano:id:AssetClass:\<policy <> name hex\>@
'cardano:Identifier' leaves the body emitter produces. Queries
join the body's input @cardano:fromTxOutRef@ →
@cardano:hasTxId@ \/ @cardano:hasIndex@ pair onto that IRI.

The needed @cardano:@ prefix is declared by
'turtlePrefixLines', which opens every lattice this module
assembles.
-}
resolvedInputTurtle
    :: Map Ledger.TxIn (TxOut ConwayEra)
    -> Text
resolvedInputTurtle utxos =
    T.intercalate
        "\n"
        (uncurry resolvedInputBlock <$> Map.toAscList utxos)

resolvedInputBlock :: Ledger.TxIn -> TxOut ConwayEra -> Text
resolvedInputBlock txIn txOut =
    T.unlines (node <> concatMap identifierBlock assets)
  where
    (txidHex, ixSuffix) = T.breakOn "#" (txInToText txIn)
    ix = T.drop 1 ixSuffix
    iri = "urn:cardano:utxo:" <> txidHex <> ":" <> ix
    addr = renderInputAddress (txOut ^. addrTxOutL)
    MaryValue (Coin lovelace) multiAsset =
        txOut ^. valueTxOutL
    assets = flattenAssets multiAsset
    node =
        [ "<" <> iri <> "> a cardano:Output ;"
        , "  cardano:hasIndex " <> ix <> " ;"
        , "  cardano:atAddress [ a cardano:Address ; cardano:bech32 \""
            <> addr
            <> "\" ] ;"
        , "  cardano:lovelace "
            <> T.pack (show lovelace)
            <> if null assets then " ." else " ;"
        ]
            <> assetValueLines
    assetValueLines
        | null assets = []
        | otherwise =
            ["  cardano:hasAssetValue ("]
                <> (assetEntry <$> assets)
                <> ["  ) ."]
    assetEntry (hex, quantity) =
        "    [ a cardano:Asset ; cardano:hasIdentifier <"
            <> assetClassIri hex
            <> "> ; cardano:quantity "
            <> T.pack (show quantity)
            <> " ]"
    identifierBlock (hex, _) =
        [ "<" <> assetClassIri hex <> "> a cardano:Identifier ;"
        , "  cardano:leafType \"AssetClass\" ;"
        , "  cardano:bytesHex \"" <> hex <> "\" ."
        ]

assetClassIri :: Text -> Text
assetClassIri hex = "urn:cardano:id:AssetClass:" <> hex

{- | Flatten a multi-asset bundle to
@(policy <> name hex, quantity)@ pairs in the deterministic
ascending order the body emitter uses.
-}
flattenAssets :: MultiAsset -> [(Text, Integer)]
flattenAssets (MultiAsset bundle) =
    [ (policyHex <> assetNameHex name, quantity)
    | (PolicyID policy, perPolicy) <- Map.toAscList bundle
    , let policyHex = scriptHashToHex policy
    , (name, quantity) <- Map.toAscList perPolicy
    ]
  where
    assetNameHex (AssetName name) =
        TE.decodeUtf8 (B16.encode (SBS.fromShort name))

decodeHex :: Text -> Maybe BS.ByteString
decodeHex =
    either (const Nothing) Just . B16.decode . TE.encodeUtf8
