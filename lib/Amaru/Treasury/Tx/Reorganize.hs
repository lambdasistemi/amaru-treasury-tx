{- |
Module      : Amaru.Treasury.Tx.Reorganize
Description : Typed intent for the reorganize action
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Resolved ledger inputs for the reorganize action. The pure build
program lands in a later slice; this slice establishes the typed
shape consumed by intent JSON translation once the dispatcher is
wired.
-}
module Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (Guard))
import Cardano.Ledger.TxIn (TxIn)
import Data.List.NonEmpty (NonEmpty)

import Amaru.Treasury.Backend (SlotNo)

-- | Resolved inputs for @reorganize@.
data ReorganizeIntent = ReorganizeIntent
    { rgiWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , rgiTreasuryUtxos :: !(NonEmpty TxIn)
    -- ^ treasury UTxOs merged into one continuing output
    , rgiTreasuryAddress :: !Addr
    -- ^ destination contract address
    , rgiTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury-script reference UTxO
    , rgiRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO
    , rgiPermissionsRewardAccount :: !AccountAddress
    -- ^ Amaru permissions reward account
    , rgiPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions withdrawal-script reference UTxO
    , rgiScopeOwnerSigner :: !(KeyHash Guard)
    -- ^ scope-owner key hash required as signer
    , rgiUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }
    deriving stock (Eq, Show)
