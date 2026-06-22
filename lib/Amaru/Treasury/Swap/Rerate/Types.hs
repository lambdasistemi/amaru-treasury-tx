{- |
Module      : Amaru.Treasury.Swap.Rerate.Types
Description : Types for pure swap re-rate planning
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Typed inputs, planned outputs, and validation errors for cancelling
pending SundaeSwap orders and re-offering their conserved ADA at a new
ADA/USDM rate.
-}
module Amaru.Treasury.Swap.Rerate.Types
    ( -- * Intent
      RerateIntent (..)
    , RerateOrder (..)
    , RerateScopeContext (..)
    , ResolvedRerateInputs (..)

      -- * Planned values
    , PlannedRerate (..)
    , PlannedRerateOrder (..)

      -- * Errors
    , RerateError (..)
    ) where

import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Hashes (KeyHash, ScriptHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import PlutusCore.Data (Data)

import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Swap (SwapOrderDatumParams (..))
import Amaru.Treasury.Tx.SwapCancel.Datum (SwapOrderDatumError)

-- | Operator-selected orders plus the new ADA/USDM rate.
data RerateIntent = RerateIntent
    { riScopeContext :: !RerateScopeContext
    -- ^ Scope ownership and Sundae datum constants.
    , riOrders :: ![RerateOrder]
    -- ^ Selected pending orders. Must be non-empty.
    , riRateNumerator :: !Integer
    -- ^ New ADA/USDM rate numerator.
    , riRateDenominator :: !Integer
    -- ^ New ADA/USDM rate denominator.
    }
    deriving stock (Eq, Show)

-- | A selected pending SundaeSwap order UTxO.
data RerateOrder = RerateOrder
    { rroTxIn :: !TxIn
    -- ^ Order UTxO to cancel in a later builder slice.
    , rroScope :: !ScopeId
    -- ^ Scope the caller attributes this order to.
    , rroValue :: !MaryValue
    -- ^ Full value currently locked at the order script.
    , rroDatum :: !Data
    -- ^ Inline SundaeSwap order datum.
    }
    deriving stock (Eq, Show)

-- | Scope facts used to validate and rebuild orders.
data RerateScopeContext = RerateScopeContext
    { rscScope :: !ScopeId
    -- ^ The single scope all selected orders must belong to.
    , rscExpectedOwners :: ![KeyHash Guard]
    -- ^ Owner key hashes expected in each order datum.
    , rscTreasuryScriptHash :: !ScriptHash
    -- ^ Treasury destination script hash expected in each order datum.
    , rscOrderExtraLovelace :: !Coin
    -- ^ Min-UTxO plus Sundae protocol-fee rider per replacement order.
    , rscDatumParams :: !SwapOrderDatumParams
    -- ^ Static fields reused by 'swapOrderDatum'.
    }

instance Eq RerateScopeContext where
    left == right =
        rscScope left == rscScope right
            && rscExpectedOwners left == rscExpectedOwners right
            && rscTreasuryScriptHash left
                == rscTreasuryScriptHash right
            && rscOrderExtraLovelace left
                == rscOrderExtraLovelace right
            && datumParamsEq
                (rscDatumParams left)
                (rscDatumParams right)

instance Show RerateScopeContext where
    showsPrec d ctx =
        showParen (d > 10) $
            showString "RerateScopeContext "
                . shows
                    ( rscScope ctx
                    , rscExpectedOwners ctx
                    , rscTreasuryScriptHash ctx
                    , rscOrderExtraLovelace ctx
                    , datumParamsShow (rscDatumParams ctx)
                    )

-- | Placeholder for future chain-resolved fields consumed by TxBuild.
newtype ResolvedRerateInputs = ResolvedRerateInputs
    { rriIntent :: RerateIntent
    -- ^ Validated high-level intent for this slice.
    }
    deriving stock (Eq, Show)

-- | Validation result consumed by the later pure TxBuild program.
data PlannedRerate = PlannedRerate
    { prScopeContext :: !RerateScopeContext
    -- ^ Scope context shared by all planned orders.
    , prOrders :: ![PlannedRerateOrder]
    -- ^ Planned replacement orders in caller order.
    }
    deriving stock (Eq, Show)

-- | Per-order cancellation and replacement value plan.
data PlannedRerateOrder = PlannedRerateOrder
    { proTxIn :: !TxIn
    -- ^ Original pending order UTxO.
    , proOriginalValue :: !MaryValue
    -- ^ Full value locked in the original order.
    , proOfferedLovelace :: !Coin
    -- ^ ADA offered to the pool, excluding the order rider.
    , proReplacementValue :: !MaryValue
    -- ^ Value for the replacement order output.
    , proReplacementDatum :: !Data
    -- ^ Replacement inline datum with the new requested USDM.
    , proRequestedUsdm :: !Integer
    -- ^ Requested USDM amount derived from the new rate.
    }
    deriving stock (Eq, Show)

-- | Typed validation failures for the re-rate planner.
data RerateError
    = RerateNoOrders
    | RerateNonPositiveRate !Integer !Integer
    | RerateOrderScopeMismatch !TxIn !ScopeId !ScopeId
    | RerateOrderDatumInvalid !TxIn !SwapOrderDatumError
    | RerateMalformedOrderDetails !TxIn
    | RerateOfferedLovelaceMismatch !TxIn !Coin !Coin
    | RerateOrderCarriesNativeAssets !TxIn
    deriving stock (Eq, Show)

datumParamsEq :: SwapOrderDatumParams -> SwapOrderDatumParams -> Bool
datumParamsEq left right =
    sodPoolId left == sodPoolId right
        && sodCoreOwner left == sodCoreOwner right
        && sodOpsOwner left == sodOpsOwner right
        && sodNetworkComplianceOwner left
            == sodNetworkComplianceOwner right
        && sodMiddlewareOwner left == sodMiddlewareOwner right
        && sodSundaeProtocolFeeLovelace left
            == sodSundaeProtocolFeeLovelace right
        && sodTreasuryScriptHash left == sodTreasuryScriptHash right
        && sodUsdmPolicy left == sodUsdmPolicy right
        && sodUsdmToken left == sodUsdmToken right

datumParamsShow :: SwapOrderDatumParams -> String
datumParamsShow p =
    "SwapOrderDatumParams "
        <> show
            ( sodPoolId p
            , sodCoreOwner p
            , sodOpsOwner p
            , sodNetworkComplianceOwner p
            , sodMiddlewareOwner p
            , sodSundaeProtocolFeeLovelace p
            , sodTreasuryScriptHash p
            , sodUsdmPolicy p
            , sodUsdmToken p
            )
