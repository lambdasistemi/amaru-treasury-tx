{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Tx.SwapCancel
Description : Pure TxBuild program for cancelling a SundaeSwap order
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Builds the pure transaction shape for retracting one pending
SundaeSwap V3 order. Effects such as order discovery, UTxO resolution,
and datum validation stay outside this module.
-}
module Amaru.Treasury.Tx.SwapCancel
    ( SwapCancelIntent (..)
    , swapCancelProgram
    ) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Control.Monad (forM_, void)

import Cardano.Node.Client.TxBuild
    ( TxBuild
    , collateral
    , payTo
    , reference
    , requireSignature
    , spend
    , spendScript
    , validTo
    )

import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , sundaeCancelRedeemer
    )

-- | Fully resolved inputs needed by the pure cancellation builder.
data SwapCancelIntent = SwapCancelIntent
    { sciWalletTxIn :: !TxIn
    -- ^ Wallet fuel input. Also used as collateral.
    , sciOrderTxIn :: !TxIn
    -- ^ Pending SundaeSwap order UTxO to spend.
    , sciOrderValue :: !MaryValue
    -- ^ Full value locked in the order UTxO.
    , sciOrderScriptRef :: !TxIn
    -- ^ Reference input containing the SundaeSwap order spending script.
    , sciTreasuryAddress :: !Addr
    -- ^ Treasury destination for the cancelled order value.
    , sciRequiredSigners :: ![KeyHash Guard]
    -- ^ Signers derived from the order datum owner policy.
    , sciUpperBound :: !SlotNo
    -- ^ Transaction invalid-hereafter slot.
    }

{- | Build a cancellation transaction:

1. spend wallet fuel;
2. use wallet fuel as collateral;
3. spend the order script input with the Sundae @Cancel@ redeemer;
4. reference the order spending script;
5. return the full order value to the treasury;
6. require every signer encoded by the order owner policy.
-}
swapCancelProgram :: SwapCancelIntent -> TxBuild q e ()
swapCancelProgram sci = do
    _ <- spend (sciWalletTxIn sci)
    collateral (sciWalletTxIn sci)
    void $
        spendScript
            (sciOrderTxIn sci)
            (RawPlutusData sundaeCancelRedeemer)
    reference (sciOrderScriptRef sci)
    void $
        payTo
            (sciTreasuryAddress sci)
            (sciOrderValue sci)
    forM_ (sciRequiredSigners sci) requireSignature
    validTo (sciUpperBound sci)
