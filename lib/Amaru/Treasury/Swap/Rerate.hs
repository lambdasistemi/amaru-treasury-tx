{- |
Module      : Amaru.Treasury.Swap.Rerate
Description : Pure TxBuild program for swap re-rate transactions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Builds the pure transaction shape for cancelling selected pending
SundaeSwap V3 orders and re-offering each conserved ADA amount at the
planned replacement rate. Order discovery, datum validation, value
planning, balancing, and phase-1 validation stay outside this module.
-}
module Amaru.Treasury.Swap.Rerate
    ( RerateProgramInputs (..)
    , rerateProgram
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Control.Monad (forM_, void)

import Cardano.Tx.Build
    ( TxBuild
    , collateral
    , payTo'
    , reference
    , requireSignature
    , spend
    , spendScript
    , validTo
    , withdrawScript
    )

import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    , sundaeCancelRedeemer
    )
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateScopeContext (..)
    )

-- | Transaction-only inputs resolved outside the pure re-rate planner.
data RerateProgramInputs = RerateProgramInputs
    { rpiWalletTxIn :: !TxIn
    -- ^ Wallet fuel input. Also used as collateral.
    , rpiOrderScriptRef :: !TxIn
    -- ^ Reference input containing the SundaeSwap order script.
    , rpiSwapOrderAddress :: !Addr
    -- ^ Destination address for every replacement order output.
    , rpiPermissionsRewardAccount :: !AccountAddress
    -- ^ Amaru permissions reward account for withdraw-zero.
    , rpiScopesDeployedAt :: !TxIn
    -- ^ Scope-owners NFT reference UTxO.
    , rpiPermissionsDeployedAt :: !TxIn
    -- ^ Deployed permissions script reference UTxO.
    , rpiTreasuryDeployedAt :: !TxIn
    -- ^ Deployed treasury script reference UTxO.
    , rpiRegistryDeployedAt :: !TxIn
    -- ^ Registry NFT reference UTxO.
    , rpiUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot.
    }
    deriving stock (Eq, Show)

{- | Build the re-rate transaction body.

The supplied 'PlannedRerate' is expected to come from
'Amaru.Treasury.Swap.Rerate.Plan.planRerate'. This function only emits
the body shape from the resolved transaction references and planned
replacement order outputs.
-}
rerateProgram
    :: RerateProgramInputs
    -> PlannedRerate
    -> TxBuild q e ()
rerateProgram inputs planned = do
    _ <- spend (rpiWalletTxIn inputs)
    collateral (rpiWalletTxIn inputs)
    forM_ (prOrders planned) $ \order ->
        void $
            spendScript
                (proTxIn order)
                (RawPlutusData sundaeCancelRedeemer)
    reference (rpiOrderScriptRef inputs)
    reference (rpiScopesDeployedAt inputs)
    reference (rpiPermissionsDeployedAt inputs)
    reference (rpiTreasuryDeployedAt inputs)
    reference (rpiRegistryDeployedAt inputs)
    withdrawScript
        (rpiPermissionsRewardAccount inputs)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    forM_ (prOrders planned) $ \order ->
        void $
            payTo'
                (rpiSwapOrderAddress inputs)
                (proReplacementValue order)
                (RawPlutusData (proReplacementDatum order))
    forM_
        (rscExpectedOwners (prScopeContext planned))
        requireSignature
    validTo (rpiUpperBound inputs)
