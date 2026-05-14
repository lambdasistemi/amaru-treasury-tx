{- |
Module      : Amaru.Treasury.Inspect.Types
Description : Public record types for the @treasury-inspect@ report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure data shapes for the inspect-report assembly. See
@specs/109-treasury-inspect/data-model.md@ for the entity model
and @specs/109-treasury-inspect/contracts/treasury-inspect-schema.json@
for the JSON shape these types must encode to.
-}
module Amaru.Treasury.Inspect.Types
    ( -- * Report
      InspectReport (..)
    , ScopeSection (..)
    , ScopeTotals (..)
    , TreasuryUtxo (..)
    , PendingSwapOrder (..)
    , Outref (..)
    , OtherAsset (..)
    , ChainTip (..)
    , DeploymentAnchor (..)

      -- * Swap-order datum (parser output, consumed by 'Inspect')
    , ParsedSwapOrder (..)
    ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word16, Word64)

import Amaru.Treasury.Scope (ScopeId, scopeText)

{- | The full report produced by one invocation of @treasury-inspect@.
Field order in the JSON encoding is alphabetical; see
'Amaru.Treasury.Inspect.Render.encodeReport'.
-}
data InspectReport = InspectReport
    { irChainTip :: !ChainTip
    , irDeployment :: !DeploymentAnchor
    , irScopes :: ![ScopeSection]
    -- ^ Stable order: as enumerated by
    --   'Amaru.Treasury.Scope.allScopes', then filtered by
    --   @--scope@ when set.
    }
    deriving (Eq, Show)

-- | Current chain tip at the moment the report was assembled.
data ChainTip = ChainTip
    { ctSlot :: !Word64
    , ctBlockHash :: !Text
    -- ^ 32-byte hex.
    }
    deriving (Eq, Show)

{- | The deployment anchor — the @scope_owners@ outref pinned in
metadata. Different deployments (mainnet, preprod, preview) have
different anchors; surfacing it lets operators detect when they
pointed inspect at the wrong metadata file.
-}
newtype DeploymentAnchor = DeploymentAnchor
    { unDeploymentAnchor :: Outref
    }
    deriving (Eq, Show)

-- | One scope's contribution to the report.
data ScopeSection = ScopeSection
    { ssScope :: !ScopeId
    , ssTreasuryAddress :: !Text
    -- ^ Bech32-encoded scope contract address.
    , ssTreasuryScriptHash :: !Text
    -- ^ 28-byte hex; the disambiguator used to attribute
    --   pending orders.
    , ssTreasuryUtxos :: ![TreasuryUtxo]
    , ssTreasuryTotals :: !ScopeTotals
    , ssPendingOrders :: ![PendingSwapOrder]
    }
    deriving (Eq, Show)

-- | Aggregates over a scope's treasury UTxOs.
data ScopeTotals = ScopeTotals
    { stLovelace :: !Integer
    , stUsdm :: !Integer
    , stOtherAssetsCount :: !Int
    -- ^ Number of distinct @(policy, assetName)@ pairs that are
    --   neither ADA nor USDM across the scope's treasury UTxOs.
    --   Surfaced so operators notice unexpected holdings at a
    --   glance.
    }
    deriving (Eq, Show)

-- | A single UTxO at a scope's treasury script address.
data TreasuryUtxo = TreasuryUtxo
    { tuOutref :: !Outref
    , tuLovelace :: !Integer
    , tuUsdm :: !Integer
    -- ^ 0 when no USDM is held.
    , tuOtherAssets :: ![OtherAsset]
    , tuDatumHash :: !(Maybe Text)
    -- ^ 32-byte hex, present when the UTxO carries a hashed
    --   datum reference.
    }
    deriving (Eq, Show)

-- | One pending SundaeSwap order attributed to a scope.
data PendingSwapOrder = PendingSwapOrder
    { psoOutref :: !Outref
    , psoLovelaceIn :: !Integer
    -- ^ ADA committed to the swap.
    , psoMinUsdmOut :: !Integer
    -- ^ Lower bound on USDM the order will accept.
    , psoSundaeFeeLovelace :: !Integer
    -- ^ SundaeSwap protocol fee embedded in the datum.
    }
    deriving (Eq, Show)

-- | A Cardano UTxO reference (@txid#ix@).
data Outref = Outref
    { orTxId :: !Text
    -- ^ 32-byte hex.
    , orIx :: !Word16
    }
    deriving (Eq, Ord, Show)

{- | Non-ADA, non-USDM asset at a treasury UTxO. Surfaced so
operators notice unexpected holdings; not consumed by any
filtering logic.
-}
data OtherAsset = OtherAsset
    { oaPolicy :: !Text
    -- ^ 28-byte hex policy id.
    , oaAssetName :: !Text
    -- ^ Hex-encoded asset name bytes; empty for the unnamed
    --   token.
    , oaQuantity :: !Integer
    }
    deriving (Eq, Show)

{- | One pending SundaeSwap order parsed from its inline datum.

The 'posDestinationTreasuryHash' field is what the inspector
uses to attribute the order to a scope — see
@specs/109-treasury-inspect/research.md@ §R1 for why this is the
correct disambiguator and not the four-scope authorised-signers
list embedded at index 1 of the order datum.
-}
data ParsedSwapOrder = ParsedSwapOrder
    { posDestinationTreasuryHash :: !ByteString
    -- ^ 28-byte hash of the funding scope's treasury script.
    , posLovelaceIn :: !Integer
    -- ^ ADA committed to the swap (chunk lovelace).
    , posMinUsdmOut :: !Integer
    -- ^ Minimum USDM the order will accept.
    , posSundaeFeeLovelace :: !Integer
    -- ^ SundaeSwap protocol fee embedded in the datum.
    }
    deriving (Eq, Show)

-- ----------------------------------------------------
-- JSON instances (kept here to avoid orphan warnings; the
-- contract is the schema in specs/109-treasury-inspect/contracts/)
-- ----------------------------------------------------

instance ToJSON InspectReport where
    toJSON r =
        object
            [ "chainTip" .= irChainTip r
            , "deployment" .= irDeployment r
            , "scopes" .= irScopes r
            ]

instance ToJSON ChainTip where
    toJSON ct =
        object
            [ "slot" .= ctSlot ct
            , "blockHash" .= ctBlockHash ct
            ]

instance ToJSON DeploymentAnchor where
    toJSON (DeploymentAnchor o) =
        object ["scopeOwnersOutref" .= o]

instance ToJSON ScopeSection where
    toJSON s =
        object
            [ "scope" .= scopeText (ssScope s)
            , "treasuryAddress" .= ssTreasuryAddress s
            , "treasuryScriptHash" .= ssTreasuryScriptHash s
            , "treasuryUtxos" .= ssTreasuryUtxos s
            , "totals" .= ssTreasuryTotals s
            , "pendingOrders" .= ssPendingOrders s
            ]

instance ToJSON ScopeTotals where
    toJSON t =
        object
            [ "lovelace" .= stLovelace t
            , "usdm" .= stUsdm t
            , "otherAssetsCount" .= stOtherAssetsCount t
            ]

instance ToJSON TreasuryUtxo where
    toJSON u =
        object
            [ "outref" .= tuOutref u
            , "lovelace" .= tuLovelace u
            , "usdm" .= tuUsdm u
            , "otherAssets" .= tuOtherAssets u
            , "datumHash" .= tuDatumHash u
            ]

instance ToJSON OtherAsset where
    toJSON a =
        object
            [ "policy" .= oaPolicy a
            , "assetName" .= oaAssetName a
            , "quantity" .= oaQuantity a
            ]

instance ToJSON PendingSwapOrder where
    toJSON p =
        object
            [ "outref" .= psoOutref p
            , "lovelaceIn" .= psoLovelaceIn p
            , "minUsdmOut" .= psoMinUsdmOut p
            , "sundaeFeeLovelace" .= psoSundaeFeeLovelace p
            ]

instance ToJSON Outref where
    toJSON o =
        object
            [ "txId" .= orTxId o
            , "ix" .= orIx o
            ]
