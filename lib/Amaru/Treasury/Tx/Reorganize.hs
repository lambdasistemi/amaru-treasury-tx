{- |
Module      : Amaru.Treasury.Tx.Reorganize
Description : Typed intent for the reorganize action
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Resolved ledger inputs and pure build program for the reorganize
action. The dispatcher path is wired in a later slice; this module
only defines the typed intent shape and transaction-builder sequence.
-}
module Amaru.Treasury.Tx.Reorganize
    ( -- * Intent
      ReorganizeIntent (..)
    , reorganizeTreasuryOutputValues

      -- * Program
    , reorganizeProgram
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (Guard))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (forM_, void)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map

import Cardano.Tx.Build
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
import Amaru.Treasury.Constants
    ( minUtxoDepositLovelace
    , nativeAssetMinUtxoDepositLovelace
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    , reorganizeRedeemer
    )

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
    , rgiScopesDeployedAt :: !TxIn
    -- ^ scopes-NFT reference UTxO. The permissions
    --   withdraw-script walks @reference_inputs@ looking
    --   for the scopes-NFT and fails phase-2 when absent.
    , rgiScopeOwnerSigner :: !(KeyHash Guard)
    -- ^ scope-owner key hash required as signer
    , rgiUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    , rgiSplitNativeAssets :: !Bool
    -- ^ when true, split mixed treasury value into one
    --     pure-ADA treasury output plus one native-asset
    --     treasury output with a minimum ADA floor
    }
    deriving stock (Eq, Show)

{- | Pure transaction-build program for @reorganize@.

The runner computes the preserved total from the frozen
'Amaru.Treasury.ChainContext.ChainContext' and supplies it here. This
program only emits the observable transaction shape: wallet fuel and
collateral, treasury script spends with the reorganize redeemer,
treasury/registry/permissions references, permissions withdraw-zero,
one continuing treasury output, the required scope-owner signer, and
the upper validity bound.
-}
reorganizeProgram
    :: ReorganizeIntent
    -> MaryValue
    -- ^ Preserved total value for the continuing treasury output.
    -> TxBuild q e ()
reorganizeProgram intent preservedValue = do
    _ <- spend (rgiWalletUtxo intent)
    collateral (rgiWalletUtxo intent)
    forM_ (NE.toList (rgiTreasuryUtxos intent)) $ \txin ->
        void $
            spendScript
                txin
                (RawPlutusData reorganizeRedeemer)
    reference (rgiTreasuryDeployedAt intent)
    reference (rgiRegistryDeployedAt intent)
    reference (rgiPermissionsDeployedAt intent)
    reference (rgiScopesDeployedAt intent)
    withdrawScript
        (rgiPermissionsRewardAccount intent)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    forM_ (reorganizeTreasuryOutputValues intent preservedValue) $
        \value ->
            void (payTo (rgiTreasuryAddress intent) value)
    requireSignature (rgiScopeOwnerSigner intent)
    validTo (rgiUpperBound intent)

reorganizeTreasuryOutputValues
    :: ReorganizeIntent
    -> MaryValue
    -> [MaryValue]
reorganizeTreasuryOutputValues intent preservedValue =
    case preservedValue of
        MaryValue (Coin lovelace) assets@(MultiAsset assetMap)
            | rgiSplitNativeAssets intent
            , not (Map.null assetMap)
            , lovelace
                >= nativeAssetMinUtxoDepositLovelace + minUtxoDepositLovelace ->
                [ MaryValue
                    (Coin (lovelace - nativeAssetMinUtxoDepositLovelace))
                    (MultiAsset Map.empty)
                , MaryValue (Coin nativeAssetMinUtxoDepositLovelace) assets
                ]
        _ -> [preservedValue]
