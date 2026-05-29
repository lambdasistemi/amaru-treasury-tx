{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Indexer.Decoder
Description : Pure per-transaction treasury history decoder
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The downstream 'DecodeTx' the shared tx-history follower
(@cardano-node-clients:tx-history-indexer-lib@) calls for every
transaction in a block. It is pure over the block's 'SlotNo' and the
raw transaction bytes carried by 'BlockTx': no UTxO lookups, no
network, no IO.

Each recognised treasury transaction yields exactly one
'TxSummaryEntry' filed under the fixed tenant
@TenantId "amaru-treasury-tx"@. The history scope is the UTF-8
'Amaru.Treasury.Scope.scopeText' of the 'Amaru.Treasury.Scope.ScopeId'
recovered from on-chain data (never the treasury script hash). The
supplied 'SlotNo' is echoed verbatim into the key, the raw transaction
id bytes are echoed as 'tskTxId', and the payload is empty.

= Role discrimination (per the slice-3 contract)

In order:

  1. @mint-registry@ — the transaction mints under a per-scope derived
     registry NFT policy ('Amaru.Treasury.Registry.Derive.derivedRegistryNftPolicy').
  2. @swap@ — label-1694 event @disburse@ with label @Swap ADA\<-\>USDM@.
  3. @withdraw@ — label-1694 event @withdraw@.
  4. @reorganize@ — label-1694 event @reorganize@.
  5. @contingency-disburse@ — label-1694 event @disburse@ whose recovered
     scope is @contingency@.
  6. @disburse@ — label-1694 event @disburse@ for any other scope.

The scope is recovered by mapping the registry policy id — the
label-1694 @instance@ string, or the minted policy for a registry mint —
back through 'derivedRegistryNftPolicy' over
'Amaru.Treasury.Scope.allScopes'.

Any transaction that fails to decode, carries no recognised treasury
signal, or whose registry policy id maps to no known scope yields
'Nothing'.
-}
module Amaru.Treasury.Indexer.Decoder
    ( -- * Re-exported upstream types
      TenantId (..)
    , TxSummaryEntry
    , BlockTx
    , mkBlockTx

      -- * Tenant
    , treasuryTenantId

      -- * Decoder
    , treasuryDecodeTx

      -- * Entry accessors
    , summaryTenant
    , summaryScope
    , summarySlot
    , summaryTxId
    , summaryPayload
    ) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (auxDataTxL, txIdTx)
import Cardano.Ledger.Api.Tx.AuxData (metadataTxAuxDataL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (DecCBOR (..), decodeFullAnnotator)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Mary.Value (MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Node.Client.TxHistoryIndexer.BlockExtract
    ( BlockTx (..)
    , mkBlockTx
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope (..)
    , TenantId (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Registry.Derive (derivedRegistryNftPolicy)
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , allScopes
    , scopeText
    )

-- | The fixed tenant under which every treasury history entry is filed.
treasuryTenantId :: TenantId
treasuryTenantId = TenantId "amaru-treasury-tx"

{- | Decode one transaction's raw bytes into the treasury history
entries it warrants, echoing the supplied block 'SlotNo' into each
key. 'Nothing' for any transaction that is not a recognised treasury
transaction.
-}
treasuryDecodeTx :: SlotNo -> BlockTx -> Maybe [TxSummaryEntry]
treasuryDecodeTx slot (BlockTx raw) = do
    tx <- decodeConwayTx raw
    (role, scope) <- classifyTx tx
    let key =
            TxSummaryKey
                { tskTenant = treasuryTenantId
                , tskScope = scopeToHistoryScope scope
                , tskSlot = slot
                , tskTxId = TxId (rawTxId tx)
                , tskRole = TxRole role
                }
    Just [TxSummaryEntry{tseKey = key, tsePayload = BS.empty}]

-- ------------------------------------------------------------
-- Classification
-- ------------------------------------------------------------

-- | Canonical ASCII role bytes filed into 'tskRole'.
roleDisburse
    , roleReorganize
    , roleWithdraw
    , roleSwap
    , roleContingencyDisburse
    , roleMintRegistry
        :: ByteString
roleDisburse = "disburse"
roleReorganize = "reorganize"
roleWithdraw = "withdraw"
roleSwap = "swap"
roleContingencyDisburse = "contingency-disburse"
roleMintRegistry = "mint-registry"

-- | The label-1694 @label@ that marks a swap disbursement.
swapLabel :: Text
swapLabel = "Swap ADA<->USDM"

{- | Recognise the treasury role and scope of a transaction, in the
contract's discrimination order. 'Nothing' for non-treasury
transactions.
-}
classifyTx :: ConwayTx -> Maybe (ByteString, ScopeId)
classifyTx tx = fromRegistryMint <|> fromRationale
  where
    fromRegistryMint = do
        scope <-
            listToMaybe
                [ s
                | policy <- mintedPolicies tx
                , Just s <- [registryPolicyScope policy]
                ]
        Just (roleMintRegistry, scope)

    fromRationale = do
        metadatum <- label1694Metadatum tx
        event <- rationaleField "event" metadatum
        scope <- rationaleInstance metadatum >>= registryPolicyScope
        classifyEvent event (rationaleField "label" metadatum) scope

    classifyEvent event mLabel scope = case event of
        "withdraw" -> Just (roleWithdraw, scope)
        "reorganize" -> Just (roleReorganize, scope)
        "disburse"
            | mLabel == Just swapLabel -> Just (roleSwap, scope)
            | scope == Contingency ->
                Just (roleContingencyDisburse, scope)
            | otherwise -> Just (roleDisburse, scope)
        _ -> Nothing

-- ------------------------------------------------------------
-- Transaction field extraction
-- ------------------------------------------------------------

-- | Decode a Conway transaction from raw bytes; 'Nothing' on failure.
decodeConwayTx :: ByteString -> Maybe ConwayTx
decodeConwayTx raw =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (BSL.fromStrict raw) of
        Right tx -> Just tx
        Left _ -> Nothing

-- | Raw transaction id bytes of a decoded transaction.
rawTxId :: ConwayTx -> ByteString
rawTxId tx = case txIdTx tx of
    Ledger.TxId safeHash -> hashToBytes (extractHash safeHash)

-- | Policy ids minted by the transaction (raw 28-byte script hashes).
mintedPolicies :: ConwayTx -> [ByteString]
mintedPolicies tx =
    case tx ^. bodyTxL . mintTxBodyL of
        MultiAsset assets ->
            [scriptHashBytes sh | PolicyID sh <- Map.keys assets]

-- | The label-1694 rationale metadatum, if present.
label1694Metadatum :: ConwayTx -> Maybe Metadatum
label1694Metadatum tx =
    case tx ^. auxDataTxL of
        SNothing -> Nothing
        SJust auxData ->
            Map.lookup label1694 (auxData ^. metadataTxAuxDataL)

{- | Read a text field nested under @body@ of the rationale metadatum
(e.g. @event@, @label@).
-}
rationaleField :: Text -> Metadatum -> Maybe Text
rationaleField field metadatum = do
    body <- metadatumLookup "body" metadatum
    value <- metadatumLookup field body
    metadatumText value

{- | Recover the registry policy id from the top-level @instance@ string
of the rationale metadatum, as raw 28 bytes.
-}
rationaleInstance :: Metadatum -> Maybe ByteString
rationaleInstance metadatum = do
    value <- metadatumLookup "instance" metadatum
    hex <- metadatumText value
    case B16.decode (TE.encodeUtf8 hex) of
        Right bytes | BS.length bytes == 28 -> Just bytes
        _ -> Nothing

-- | Look up a string-keyed entry of a metadatum map.
metadatumLookup :: Text -> Metadatum -> Maybe Metadatum
metadatumLookup key = \case
    Map entries -> lookup (S key) entries
    _ -> Nothing

-- | Project the 'Text' of a string metadatum.
metadatumText :: Metadatum -> Maybe Text
metadatumText = \case
    S text -> Just text
    _ -> Nothing

-- ------------------------------------------------------------
-- Scope derivation
-- ------------------------------------------------------------

-- | Map a registry NFT policy id back to its 'ScopeId'.
registryPolicyScope :: ByteString -> Maybe ScopeId
registryPolicyScope policy = lookup policy registryPolicyScopes

{- | The registry NFT policy id of every scope, paired with the scope.
Computed once from the pinned validator blobs.
-}
registryPolicyScopes :: [(ByteString, ScopeId)]
registryPolicyScopes =
    [ (scriptHashBytes hash, scope)
    | scope <- allScopes
    , Right hash <- [derivedRegistryNftPolicy scope]
    ]

-- | Render a scope as its 'HistoryScope' (UTF-8 'scopeText').
scopeToHistoryScope :: ScopeId -> HistoryScope
scopeToHistoryScope = HistoryScope . TE.encodeUtf8 . scopeText

-- | Raw bytes of a ledger script hash.
scriptHashBytes :: ScriptHash -> ByteString
scriptHashBytes (ScriptHash hash) = hashToBytes hash

-- ------------------------------------------------------------
-- Entry accessors
-- ------------------------------------------------------------

-- | Tenant of a decoded entry.
summaryTenant :: TxSummaryEntry -> TenantId
summaryTenant = tskTenant . tseKey

-- | History scope of a decoded entry, as UTF-8 text.
summaryScope :: TxSummaryEntry -> Text
summaryScope = TE.decodeUtf8 . unHistoryScope . tskScope . tseKey

-- | Slot of a decoded entry.
summarySlot :: TxSummaryEntry -> SlotNo
summarySlot = tskSlot . tseKey

-- | Raw transaction-id bytes of a decoded entry.
summaryTxId :: TxSummaryEntry -> ByteString
summaryTxId = unTxId . tskTxId . tseKey

-- | Opaque payload of a decoded entry.
summaryPayload :: TxSummaryEntry -> ByteString
summaryPayload = tsePayload
