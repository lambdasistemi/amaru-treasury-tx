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

Each recognised outbound treasury transaction yields exactly one
'TxSummary' filed under the fixed tenant
@TenantId "amaru-treasury-tx"@. The history scope is the UTF-8
'Amaru.Treasury.Scope.scopeText' of the 'Amaru.Treasury.Scope.ScopeId'
recovered from on-chain data (never the treasury script hash). The
supplied 'SlotNo' is echoed verbatim into the key, the raw transaction
id bytes are echoed as 'tskTxId', and the compatibility list payload is
empty. The detail fields are populated only from the transaction body
and witnesses carried by 'BlockTx': no node lookup and no UTxO scan.

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
    , TxSummary
    , TxSummaryEntry
    , TxSummaryInput
    , TxSummaryOutput
    , BlockTx
    , mkBlockTx

      -- * Tenant
    , treasuryTenantId

      -- * Decoder
    , treasuryDecodeTx
    , treasuryDecodeTxWith
    , treasuryDecodeTxWithInterest
    , decodeConwayTx

      -- * Dynamic registry-policy scope mappings
    , registryScopeMappingsFromMetadata
    , scopeAddressMappingsFromMetadata

      -- * Entry accessors
    , summaryTenant
    , summaryScope
    , summarySlot
    , summaryTxId
    , summaryPayload
    , summaryInputs
    , summaryOutputs
    , summaryRedeemer
    , summaryFee
    , summaryRequiredSigners
    , summaryBlockHash
    , summaryDirection
    ) where

import Control.Applicative ((<|>))
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Either (fromRight)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (auxDataTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.AuxData (metadataTxAuxDataL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , txIxToInt
    )
import Cardano.Ledger.Binary (DecCBOR (..), decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , extractHash
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.Plutus.Data qualified as PlutusData
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32

import Cardano.Node.Client.TxHistoryIndexer.BlockExtract
    ( BlockTx (..)
    , mkBlockTx
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope (..)
    , TenantId (..)
    , TxDirection (..)
    , TxId (..)
    , TxRole (..)
    , TxSummary (..)
    , TxSummaryEntry (..)
    , TxSummaryInput (..)
    , TxSummaryKey (..)
    , TxSummaryOutput (..)
    )

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Registry.Derive (derivedRegistryNftPolicy)
import Amaru.Treasury.Report.Accounting (valueSummary)
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

Uses only the statically derived per-scope registry NFT policies
(the pinned mainnet seed). Deployments whose registry policies are
derived from a per-instance seed (e.g. the devnet bootstrap) must use
'treasuryDecodeTxWith' with the extra mappings recovered from their
deployment metadata.
-}
treasuryDecodeTx :: SlotNo -> BlockTx -> Maybe [TxSummary]
treasuryDecodeTx = treasuryDecodeTxWith []

{- | Like 'treasuryDecodeTx', but consults @extra@ registry-policy →
'ScopeId' mappings before the static pinned-seed table. The extra
mappings win on conflict, so a deployment that derives its registry
NFT policies from a per-instance seed (the devnet bootstrap, or any
non-mainnet instance) can map its own rationale @instance@ /
registry-mint policy ids to a scope. The static table remains the
fallback so mainnet treasury txs keep decoding with no extra config.
-}
treasuryDecodeTxWith
    :: [(ByteString, ScopeId)]
    -> SlotNo
    -> BlockTx
    -> Maybe [TxSummary]
treasuryDecodeTxWith extra = treasuryDecodeTxWithInterest extra []

{- | Decode treasury actions plus inbound funding. The first mapping is
@registry-policy-id -> scope@ for outbound treasury roles; the second is
@bech32 treasury-address -> scope@ for plain funding transactions whose
outputs pay into a treasury scope without running a treasury validator.
-}
treasuryDecodeTxWithInterest
    :: [(ByteString, ScopeId)]
    -> [(ByteString, ScopeId)]
    -> SlotNo
    -> BlockTx
    -> Maybe [TxSummary]
treasuryDecodeTxWithInterest registryMappings addressMappings slot (BlockTx raw) = do
    tx <- decodeConwayTx raw
    case classifyTx registryMappings tx of
        Just (role, scope) ->
            Just [summaryFor tx directionOutbound (Just role) scope]
        Nothing ->
            case inboundScopes addressMappings tx of
                [] -> Nothing
                scopes ->
                    Just
                        [ summaryFor tx directionInbound Nothing scope
                        | scope <- scopes
                        ]
  where
    summaryFor tx direction mRole scope =
        let role = fromMaybe BS.empty mRole
            key =
                TxSummaryKey
                    { tskTenant = treasuryTenantId
                    , tskScope = scopeToHistoryScope scope
                    , tskSlot = slot
                    , tskTxId = TxId (rawTxId tx)
                    , tskRole = TxRole role
                    }
        in  TxSummary
                { txsKey = key
                , txsPayload = raw
                , txsInputs = txInputs tx
                , txsOutputs = txOutputs tx
                , txsRedeemer = txRedeemerSummary tx <$> mRole <*> pure scope
                , txsFee = txFee tx
                , txsRequiredSigners = txRequiredSigners tx
                , txsBlockHash = Nothing
                , txsDirection = direction
                }

directionOutbound, directionInbound :: TxDirection
directionOutbound = TxDirection "outbound"
directionInbound = TxDirection "inbound"

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
classifyTx
    :: [(ByteString, ScopeId)] -> ConwayTx -> Maybe (ByteString, ScopeId)
classifyTx extra tx = fromRegistryMint <|> fromRationale
  where
    scopeOf = registryPolicyScope extra

    fromRegistryMint = do
        scope <-
            listToMaybe
                [ s
                | policy <- mintedPolicies tx
                , Just s <- [scopeOf policy]
                ]
        Just (roleMintRegistry, scope)

    fromRationale = do
        metadatum <- label1694Metadatum tx
        event <- rationaleField "event" metadatum
        scope <- rationaleInstance metadatum >>= scopeOf
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

inboundScopes :: [(ByteString, ScopeId)] -> ConwayTx -> [ScopeId]
inboundScopes addressMappings tx =
    unique
        [ scope
        | txOut <- toList (tx ^. bodyTxL . outputsTxBodyL)
        , Just scope <-
            [ lookup
                (textBytes (renderAddress (txOut ^. addrTxOutL)))
                addressMappings
            ]
        ]

unique :: (Ord a) => [a] -> [a]
unique = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
        | x `Set.member` seen = go seen xs
        | otherwise = x : go (Set.insert x seen) xs

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

{- | Transaction inputs in deterministic ledger order. Values and
owning scopes require previous-output context, so the pure decoder
records them as unknown rather than consulting the node.
-}
txInputs :: ConwayTx -> [TxSummaryInput]
txInputs tx =
    [ TxSummaryInput
        { tsiTxIn = textBytes (renderTxIn txIn)
        , tsiScope = Nothing
        , tsiValue = "unknown"
        }
    | txIn <- Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
    ]

-- | Transaction outputs rendered in body order.
txOutputs :: ConwayTx -> [TxSummaryOutput]
txOutputs tx =
    [ TxSummaryOutput
        { tsoAddress = textBytes (renderAddress (txOut ^. addrTxOutL))
        , tsoValue = valueBytes (txOut ^. valueTxOutL)
        , tsoDatum = textBytes <$> datumSummary (txOut ^. datumTxOutL)
        }
    | txOut <- toList (tx ^. bodyTxL . outputsTxBodyL)
    ]

txFee :: ConwayTx -> Maybe Word64
txFee tx =
    let Coin fee = tx ^. bodyTxL . feeTxBodyL
    in  Just (fromIntegral fee)

txRequiredSigners :: ConwayTx -> [ByteString]
txRequiredSigners tx =
    textBytes . renderKeyHash
        <$> Set.toAscList (tx ^. bodyTxL . reqSignerHashesTxBodyL)

txRedeemerSummary :: ConwayTx -> ByteString -> ScopeId -> ByteString
txRedeemerSummary tx role scope =
    textBytes $
        T.intercalate
            " "
            [ "scope=" <> scopeText scope
            , "role=" <> TE.decodeUtf8 role
            , "redeemers=" <> T.pack (show (redeemerCount tx))
            , "payload=" <> rolePayloadSummary tx
            ]

redeemerCount :: ConwayTx -> Int
redeemerCount tx =
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    in  Map.size redeemers

rolePayloadSummary :: ConwayTx -> Text
rolePayloadSummary tx =
    case label1694Metadatum tx of
        Just metadatum ->
            T.intercalate
                ","
                [ "event=" <> field "event" metadatum
                , "label=" <> field "label" metadatum
                , "instance=" <> instanceField metadatum
                ]
        Nothing ->
            "mintedPolicies="
                <> T.intercalate "," (hexText <$> mintedPolicies tx)
  where
    field name metadatum = fromMaybe "-" (rationaleField name metadatum)
    instanceField metadatum =
        fromMaybe
            "-"
            (metadatumLookup "instance" metadatum >>= metadatumText)

datumSummary :: PlutusData.Datum ConwayEra -> Maybe Text
datumSummary = \case
    PlutusData.NoDatum -> Nothing
    PlutusData.DatumHash h ->
        Just ("datumHash:" <> hexText (hashToBytes (extractHash h)))
    PlutusData.Datum _ -> Just "inlineDatum"

renderAddress :: Addr -> Text
renderAddress addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        fromRight
            (error "renderAddress: invalid hrp")
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

renderTxIn :: Ledger.TxIn -> Text
renderTxIn (Ledger.TxIn (Ledger.TxId h) ix) =
    hexText (hashToBytes (extractHash h))
        <> "#"
        <> T.pack (show (txIxToInt ix))

renderKeyHash :: KeyHash discriminator -> Text
renderKeyHash (KeyHash h) =
    hexText (hashToBytes h)

textBytes :: Text -> ByteString
textBytes = TE.encodeUtf8

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

valueBytes :: MaryValue -> ByteString
valueBytes =
    BSL.toStrict . encode . valueSummary

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

{- | Map a registry NFT policy id back to its 'ScopeId', consulting
the caller-supplied @extra@ mappings first and falling back to the
static pinned-seed table.
-}
registryPolicyScope
    :: [(ByteString, ScopeId)] -> ByteString -> Maybe ScopeId
registryPolicyScope extra policy =
    lookup policy extra <|> lookup policy registryPolicyScopes

{- | The registry NFT policy id of every scope, paired with the scope.
Computed once from the pinned validator blobs.
-}
registryPolicyScopes :: [(ByteString, ScopeId)]
registryPolicyScopes =
    [ (scriptHashBytes hash, scope)
    | scope <- allScopes
    , Right hash <- [derivedRegistryNftPolicy scope]
    ]

{- | Recover the @registry-policy-id → 'ScopeId'@ mappings carried by
a deployment's 'TreasuryMetadata'. Each scope's @registry_script.hash@
is the 28-byte registry NFT policy id (lower-hex); entries whose hash
is not valid hex are dropped. Suitable as the @extra@ argument to
'treasuryDecodeTxWith' for any deployment (devnet or other
per-instance seed) whose registry policies are not the pinned-seed
statics.
-}
registryScopeMappingsFromMetadata
    :: TreasuryMetadata -> [(ByteString, ScopeId)]
registryScopeMappingsFromMetadata metadata =
    [ (bytes, scope)
    | (scope, scopeMeta) <- Map.toList (tmTreasuries metadata)
    , Right bytes <-
        [B16.decode (TE.encodeUtf8 (srHash (smRegistry scopeMeta)))]
    ]

{- | Recover the @bech32 treasury-address -> 'ScopeId'@ mappings carried
by deployment metadata. The inbound-funding detector compares rendered
transaction output addresses to these bytes.
-}
scopeAddressMappingsFromMetadata
    :: TreasuryMetadata -> [(ByteString, ScopeId)]
scopeAddressMappingsFromMetadata metadata =
    [ (TE.encodeUtf8 (smAddress scopeMeta), scope)
    | (scope, scopeMeta) <- Map.toList (tmTreasuries metadata)
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

-- | Tenant of a decoded summary.
summaryTenant :: TxSummary -> TenantId
summaryTenant = tskTenant . txsKey

-- | History scope of a decoded summary, as UTF-8 text.
summaryScope :: TxSummary -> Text
summaryScope = TE.decodeUtf8 . unHistoryScope . tskScope . txsKey

-- | Slot of a decoded summary.
summarySlot :: TxSummary -> SlotNo
summarySlot = tskSlot . txsKey

-- | Raw transaction-id bytes of a decoded summary.
summaryTxId :: TxSummary -> ByteString
summaryTxId = unTxId . tskTxId . txsKey

-- | Opaque compatibility payload of a decoded summary.
summaryPayload :: TxSummary -> ByteString
summaryPayload = txsPayload

summaryInputs :: TxSummary -> [TxSummaryInput]
summaryInputs = txsInputs

summaryOutputs :: TxSummary -> [TxSummaryOutput]
summaryOutputs = txsOutputs

summaryRedeemer :: TxSummary -> Maybe ByteString
summaryRedeemer = txsRedeemer

summaryFee :: TxSummary -> Maybe Word64
summaryFee = txsFee

summaryRequiredSigners :: TxSummary -> [ByteString]
summaryRequiredSigners = txsRequiredSigners

summaryBlockHash :: TxSummary -> Maybe ByteString
summaryBlockHash = txsBlockHash

summaryDirection :: TxSummary -> ByteString
summaryDirection = unTxDirection . txsDirection
