{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Transaction fixtures for
'Amaru.Treasury.Indexer.DecoderSpec'.

Each treasury role is represented by a 'RoleFixture' carrying the
decodable 'BlockTx', the UTF-8 scope text the decoder must surface,
and the raw transaction-id bytes the decoder must echo.

The four roles with on-disk CBOR fixtures (@disburse@, @reorganize@,
@withdraw@, @swap@) embed the existing full-transaction hex. The two
fixture-less roles (@contingency-disburse@, @mint-registry@) are
synthesised by decoding the embedded disburse transaction and
rewriting just the field the role turns on — the label-1694
@instance@ for contingency, the mint for the registry mint — then
re-encoding. No new @test/fixtures/@ are added.
-}
module Amaru.Treasury.Indexer.DecoderFixtures
    ( RoleFixture (..)
    , disburseFixture
    , reorganizeFixture
    , withdrawFixture
    , swapFixture
    , contingencyDisburseFixture
    , mintRegistryFixture
    , inboundFundingFixture
    , inboundFundingAddress
    , invalidBlockTx
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.FileEmbed (embedFile)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (.~), (^.))

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
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    , serialize
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32

import Amaru.Treasury.Indexer.Decoder (BlockTx, mkBlockTx)

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Registry.Derive
    ( derivedRegistryNftPolicy
    , scriptHashToHex
    )
import Amaru.Treasury.Scope (ScopeId (..), scopeText)

-- | A single role's decode expectation.
data RoleFixture = RoleFixture
    { fixtureTx :: BlockTx
    -- ^ The block transaction handed to 'treasuryDecodeTx'.
    , fixtureScope :: Text
    -- ^ UTF-8 scope text the decoded entry must carry.
    , fixtureTxId :: ByteString
    -- ^ Raw transaction-id bytes the decoded entry must echo.
    }

-- ------------------------------------------------------------
-- On-disk fixtures (full Conway transaction hex)
-- ------------------------------------------------------------

disburseHex :: ByteString
disburseHex = $(embedFile "test/fixtures/disburse/ada/body.cbor")

reorganizeHex :: ByteString
reorganizeHex =
    $(embedFile "test/fixtures/reorganize-core/synthetic/expected.cbor")

withdrawHex :: ByteString
withdrawHex =
    $(embedFile "test/fixtures/withdraw/synthetic/expected.cbor")

swapHex :: ByteString
swapHex = $(embedFile "test/fixtures/swap/expected.cbor")

-- | @disburse@ — scope @core_development@.
disburseFixture :: RoleFixture
disburseFixture = onDiskFixture (scopeText CoreDevelopment) disburseHex

{- | @reorganize@ — scope @network_compliance@ (the registry policy id
carried in this fixture's label-1694 @instance@).
-}
reorganizeFixture :: RoleFixture
reorganizeFixture =
    onDiskFixture (scopeText NetworkCompliance) reorganizeHex

{- | @withdraw@ — scope @network_compliance@ (the registry policy id
carried in this fixture's label-1694 @instance@).
-}
withdrawFixture :: RoleFixture
withdrawFixture =
    onDiskFixture (scopeText NetworkCompliance) withdrawHex

-- | @swap@ — scope @network_compliance@.
swapFixture :: RoleFixture
swapFixture = onDiskFixture (scopeText NetworkCompliance) swapHex

-- ------------------------------------------------------------
-- Synthetic fixtures (decode the disburse tx, rewrite one field)
-- ------------------------------------------------------------

{- | @contingency-disburse@ — the disburse transaction with its
label-1694 @instance@ rewritten to the @contingency@ registry policy.
-}
contingencyDisburseFixture :: RoleFixture
contingencyDisburseFixture =
    syntheticFixture (scopeText Contingency) $
        rewriteInstance
            (registryPolicyHex Contingency)
            disburseBaseTx

{- | @mint-registry@ — the disburse transaction with a mint added under
the @core_development@ registry policy.
-}
mintRegistryFixture :: RoleFixture
mintRegistryFixture =
    syntheticFixture (scopeText CoreDevelopment) $
        disburseBaseTx
            & bodyTxL . mintTxBodyL .~ registryMint CoreDevelopment

{- | Plain inbound funding: reuse the disburse body (so it pays to the
core treasury address), but remove rationale metadata and redeemers so
the decoder classifies it only through the output address mapping.
-}
inboundFundingFixture :: RoleFixture
inboundFundingFixture =
    syntheticFixture (scopeText CoreDevelopment) inboundFundingTx

inboundFundingAddress :: ByteString
inboundFundingAddress = TE.encodeUtf8 (firstOutputAddress inboundFundingTx)

inboundFundingTx :: ConwayTx
inboundFundingTx =
    disburseBaseTx
        & auxDataTxL .~ SNothing
        & witsTxL . rdmrsTxWitsL .~ Redeemers Map.empty

-- | A 'BlockTx' whose bytes are not a Conway transaction.
invalidBlockTx :: BlockTx
invalidBlockTx = mkBlockTx (TE.encodeUtf8 "not-a-treasury-transaction")

-- ------------------------------------------------------------
-- Builders
-- ------------------------------------------------------------

-- | Build a fixture from on-disk hex, keeping the original bytes.
onDiskFixture :: Text -> ByteString -> RoleFixture
onDiskFixture scope hex =
    let raw = decodeHex hex
    in  RoleFixture
            { fixtureTx = mkBlockTx raw
            , fixtureScope = scope
            , fixtureTxId = rawTxId (decodeTxOrError "fixture" raw)
            }

-- | Build a fixture from a synthesised transaction, re-encoding it.
syntheticFixture :: Text -> ConwayTx -> RoleFixture
syntheticFixture scope tx =
    let raw = BSL.toStrict (serialize (eraProtVerLow @ConwayEra) tx)
    in  RoleFixture
            { fixtureTx = mkBlockTx raw
            , fixtureScope = scope
            , fixtureTxId = rawTxId tx
            }

-- | The decoded disburse transaction, the base for both synthetics.
disburseBaseTx :: ConwayTx
disburseBaseTx = decodeTxOrError "disburse-base" (decodeHex disburseHex)

-- | Rewrite the top-level label-1694 @instance@ string.
rewriteInstance :: Text -> ConwayTx -> ConwayTx
rewriteInstance newInstance tx =
    tx
        & auxDataTxL
            %~ fmap
                ( metadataTxAuxDataL
                    %~ Map.adjust (setInstance newInstance) label1694
                )

-- | Replace the @instance@ entry of a rationale metadatum map.
setInstance :: Text -> Metadatum -> Metadatum
setInstance value = \case
    Map entries -> Map (map replace entries)
    other -> other
  where
    replace (S "instance", _) = (S "instance", S value)
    replace entry = entry

-- | A single-asset mint under a scope's registry NFT policy.
registryMint :: ScopeId -> MultiAsset
registryMint scope =
    case derivedRegistryNftPolicy scope of
        Right hash ->
            MultiAsset
                ( Map.singleton
                    (PolicyID hash)
                    (Map.singleton (AssetName "registry") 1)
                )
        Left err -> error ("registry mint: " <> err)

-- | Hex of a scope's registry NFT policy id (the @instance@ form).
registryPolicyHex :: ScopeId -> Text
registryPolicyHex scope =
    case derivedRegistryNftPolicy scope of
        Right hash -> scriptHashToHex hash
        Left err -> error ("registry policy: " <> err)

-- | Decode a Conway transaction or fail loudly (GREEN expects success).
decodeTxOrError :: String -> ByteString -> ConwayTx
decodeTxOrError label raw =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (BSL.fromStrict raw) of
        Right tx -> tx
        Left err -> error (label <> ": " <> show err)

-- | Raw transaction id bytes of a decoded transaction.
rawTxId :: ConwayTx -> ByteString
rawTxId tx = case txIdTx tx of
    Ledger.TxId safeHash -> hashToBytes (extractHash safeHash)

firstOutputAddress :: ConwayTx -> Text
firstOutputAddress tx =
    case toList (tx ^. bodyTxL . outputsTxBodyL) of
        txOut : _ -> renderAddress (txOut ^. addrTxOutL)
        [] -> error "firstOutputAddress: fixture has no outputs"

renderAddress :: Addr -> Text
renderAddress addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        case Bech32.humanReadablePartFromText (addressHrp addr) of
            Right value -> value
            Left err -> error ("renderAddress: " <> show err)
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

-- | Decode base16 fixture contents, ignoring surrounding whitespace.
decodeHex :: ByteString -> ByteString
decodeHex hex =
    case B16.decode (BS.filter (`notElem` whitespace) hex) of
        Right raw -> raw
        Left err -> error ("fixture hex: " <> err)
  where
    whitespace :: [Word8]
    whitespace = [0x20, 0x09, 0x0a, 0x0d]
