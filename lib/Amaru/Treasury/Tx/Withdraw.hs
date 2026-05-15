{- |
Module      : Amaru.Treasury.Tx.Withdraw
Description : Pure TxBuild program for the @withdraw@ subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`journal/2026/bin/withdraw.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/withdraw.sh):
pull rewards from the treasury reward account into the
treasury contract address.

No permissions co-approval is required (the treasury
validator's @withdraw@ purpose only checks output
shape), so this program is structurally simpler than
@disburse@/@reorganize@: one wallet input as fuel +
collateral, one withdrawal entry, one output to the
treasury, and the deployed treasury / registry scripts
as references.

The intent type carries already-resolved ledger values
('TxIn', 'AccountAddress', 'Addr', 'Coin', 'SlotNo').
The 'Main' module is responsible for the
@Text → ledger@ lift via 'Amaru.Treasury.LedgerParse'.
-}
module Amaru.Treasury.Tx.Withdraw
    ( -- * Intent
      WithdrawIntent (..)

      -- * Program
    , withdrawProgram
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Data.Map.Strict qualified as Map

import Cardano.Tx.Build
    ( TxBuild
    , collateral
    , payTo
    , reference
    , spend
    , validTo
    , withdrawScript
    )

import Amaru.Treasury.Backend (SlotNo)
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )

-- | Resolved inputs for @withdraw@.
data WithdrawIntent = WithdrawIntent
    { wiWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , wiTreasuryRewardAccount :: !AccountAddress
    -- ^ reward account whose balance we pull
    , wiTreasuryAddress :: !Addr
    -- ^ destination contract address (same scope's treasury)
    , wiTreasuryDeployedAt :: !TxIn
    -- ^ reference UTxO carrying the deployed treasury script
    , wiRegistryDeployedAt :: !TxIn
    -- ^ reference UTxO carrying the registry NFT (read-only)
    , wiRewardsAmount :: !Coin
    -- ^ rewards balance (queried separately by the runner)
    , wiUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }

{- | The pure transaction-build program: spend wallet
fuel, withdraw the rewards via the treasury script,
forward them to the treasury contract address, attach
the deployed treasury and registry references, set
validity bound. No permissions, no co-signers, no
auxiliary metadata at this stage.
-}
withdrawProgram :: WithdrawIntent -> TxBuild q e ()
withdrawProgram wi = do
    _ <- spend (wiWalletUtxo wi)
    collateral (wiWalletUtxo wi)
    reference (wiTreasuryDeployedAt wi)
    reference (wiRegistryDeployedAt wi)
    withdrawScript
        (wiTreasuryRewardAccount wi)
        (wiRewardsAmount wi)
        (RawPlutusData emptyListRedeemer)
    _ <-
        payTo
            (wiTreasuryAddress wi)
            (lovelaceValue (wiRewardsAmount wi))
    validTo (wiUpperBound wi)

-- | Wrap a 'Coin' into a pure-ADA 'MaryValue'.
lovelaceValue :: Coin -> MaryValue
lovelaceValue c = MaryValue c (MultiAsset Map.empty)
