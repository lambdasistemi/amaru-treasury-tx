{- |
Module      : Amaru.Treasury.Tx.Disburse
Description : Pure TxBuild program for the @disburse@ subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`journal/2026/bin/disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh)
+
[`journal/2026/lib/build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh)
for the **ADA** disburse case (single beneficiary,
leftover back to the treasury). USDM and the multi-output
swap shape (the one in
[`swap.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/swap.sh))
are deliberately out of scope here; they layer on top in
follow-up modules.

The intent type carries already-resolved ledger values.
'Main' is responsible for the @Text → ledger@ lift (via
'Amaru.Treasury.LedgerParse') and the UTxO selection
(via 'Amaru.Treasury.UtxoSelect').
-}
module Amaru.Treasury.Tx.Disburse
    ( -- * Intent
      DisburseIntent (..)

      -- * Program
    , disburseAdaProgram
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map

import Cardano.Node.Client.TxBuild
    ( TxBuild
    , collateral
    , payTo
    , reference
    , requireSignature
    , spend
    , spendScript
    , validTo
    , withdrawScript
    )

import Amaru.Treasury.Backend (SlotNo)
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , disburseAdaRedeemer
    , emptyListRedeemer
    )

-- | Resolved inputs for an ADA @disburse@.
data DisburseIntent = DisburseIntent
    { diWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , diBeneficiaryAddress :: !Addr
    -- ^ payee of the disbursement
    , diAmountLovelace :: !Coin
    -- ^ amount of ADA to send to the beneficiary
    , diLeftoverLovelace :: !Coin
    -- ^ leftover ADA returned to the treasury address
    , diTreasuryUtxos :: ![TxIn]
    -- ^ pre-selected treasury UTxOs to be spent
    , diTreasuryAddress :: !Addr
    -- ^ treasury contract address (leftover destination)
    , diPermissionsRewardAccount :: !AccountAddress
    -- ^ Amaru permissions reward account (withdraw-zero target)
    , diScopesDeployedAt :: !TxIn
    -- ^ scope-owners NFT reference UTxO
    , diPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions script reference UTxO
    , diTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury script reference UTxO
    , diRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO
    , diSigners :: ![KeyHash Guard]
    -- ^ scope owner + witness scope owners (TxBuild uses
    --     the @Guard@ role for required-signer keyhashes)
    , diUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }

{- | Build the ADA disburse transaction. Mirrors
@build_transaction.sh@: spend wallet fuel + treasury
UTxOs, attach the four reference inputs (scopes,
permissions, treasury, registry), withdraw-zero on the
permissions reward account, two outputs (leftover →
treasury, amount → beneficiary), required signers, and
the validity upper bound.
-}
disburseAdaProgram :: DisburseIntent -> TxBuild q e ()
disburseAdaProgram di = do
    _ <- spend (diWalletUtxo di)
    collateral (diWalletUtxo di)
    let spendRedeemer =
            RawPlutusData $
                disburseAdaRedeemer (unCoin (diAmountLovelace di))
    forM_ (diTreasuryUtxos di) $ \txin ->
        void (spendScript txin spendRedeemer)
    reference (diScopesDeployedAt di)
    reference (diPermissionsDeployedAt di)
    reference (diTreasuryDeployedAt di)
    reference (diRegistryDeployedAt di)
    withdrawScript
        (diPermissionsRewardAccount di)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    _ <-
        payTo
            (diTreasuryAddress di)
            (lovelaceValue (diLeftoverLovelace di))
    _ <-
        payTo
            (diBeneficiaryAddress di)
            (lovelaceValue (diAmountLovelace di))
    forM_ (diSigners di) requireSignature
    validTo (diUpperBound di)

-- | Wrap a 'Coin' into a pure-ADA 'MaryValue'.
lovelaceValue :: Coin -> MaryValue
lovelaceValue c = MaryValue c (MultiAsset Map.empty)
