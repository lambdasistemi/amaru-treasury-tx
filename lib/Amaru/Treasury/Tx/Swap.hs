{- |
Module      : Amaru.Treasury.Tx.Swap
Description : Pure TxBuild program for the @swap@ subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`journal/2026/bin/swap.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/swap.sh)
+
[`journal/2026/lib/build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh):
spend the wallet fuel + N treasury UTxOs, attach the
four reference inputs, withdraw-zero on the permissions
reward account, emit one inline-datum output per
swap-order chunk, and append the leftover treasury
output last.

The 'SwapIntent' carries already-resolved ledger inputs
including the per-chunk inline 'Data' values; computing
chunk sizes and building the SundaeSwap datum lives in
the caller (see 'swapOrderDatum' for the datum shape).
-}
module Amaru.Treasury.Tx.Swap
    ( -- * Intent
      SwapIntent (..)
    , SwapOrderOut (..)
    , LeftoverAsset (..)

      -- * Program
    , swapProgram

      -- * SundaeSwap order datum
    , SwapOrderDatumParams (..)
    , swapOrderDatum
    ) where

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import PlutusCore.Data (Data (..))

import Cardano.Node.Client.TxBuild
    ( TxBuild
    , collateral
    , payTo
    , payTo'
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

-- | A single swap-order output: chunk lovelace + inline datum.
data SwapOrderOut = SwapOrderOut
    { soLovelace :: !Coin
    -- ^ chunk amount of lovelace going INTO the swap order
    --     (the actual output value adds the Sundae fee + min UTxO
    --     deposit; see 'siSwapOrderExtraLovelace')
    , soDatum :: !Data
    -- ^ inline 'Data' describing the SundaeSwap order
    }

-- | Optional native-asset addendum for the leftover treasury output.
data LeftoverAsset = LeftoverAsset
    { laPolicy :: !PolicyID
    , laAsset :: !AssetName
    , laQuantity :: !Integer
    }

{- | Resolved inputs for a multi-output @swap@ tx.

Mirrors swap.sh's argument layout: chunk sizes have
already been computed by the caller (full + remainder);
the leftover treasury output is the final 'TxOut' on the
ledger ordering, matching the corrected swap.sh that
appends the leftover *after* the chunk loop.
-}
data SwapIntent = SwapIntent
    { siWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , siSwapOrderAddress :: !Addr
    -- ^ destination for every swap-order output
    , siSwapOrders :: ![SwapOrderOut]
    -- ^ ordered chunks; one inline-datum output per entry
    , siSwapOrderExtraLovelace :: !Coin
    -- ^ Sundae protocol fee + min UTxO deposit added to
    --     each swap-order output's value
    , siTreasuryUtxos :: ![TxIn]
    -- ^ pre-selected treasury UTxOs to be spent
    , siTreasuryAddress :: !Addr
    -- ^ treasury contract address (leftover destination)
    , siTreasuryLeftoverLovelace :: !Coin
    -- ^ leftover lovelace returned to the treasury
    , siTreasuryLeftoverAsset :: !(Maybe LeftoverAsset)
    -- ^ optional USDM (or other native asset) bundled
    --     with the leftover treasury output
    , siRedeemerAmountLovelace :: !Coin
    -- ^ ADA quantity recorded in the Sundae @Disburse@
    --     redeemer (= sum of swap-order chunks)
    , siPermissionsRewardAccount :: !AccountAddress
    -- ^ Amaru permissions reward account (withdraw-zero target)
    , siScopesDeployedAt :: !TxIn
    -- ^ scope-owners NFT reference UTxO
    , siPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions script reference UTxO
    , siTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury script reference UTxO
    , siRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO
    , siSigners :: ![KeyHash Guard]
    -- ^ scope owner + witness scope owners
    , siUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }

{- | Build the swap transaction. Mirrors @swap.sh@:

1. spend wallet fuel (also collateral)
2. spend each treasury UTxO with the disburse redeemer
3. attach scopes, permissions, treasury, registry references
4. withdraw-zero on the permissions reward account
5. one swap-order output per chunk (with inline datum)
6. leftover treasury output (after the chunk loop)
7. required signers + validity upper bound
-}
swapProgram :: SwapIntent -> TxBuild q e ()
swapProgram si = do
    _ <- spend (siWalletUtxo si)
    collateral (siWalletUtxo si)
    let spendRedeemer =
            RawPlutusData $
                disburseAdaRedeemer
                    (unCoin (siRedeemerAmountLovelace si))
    forM_ (siTreasuryUtxos si) $ \txin ->
        void (spendScript txin spendRedeemer)
    reference (siScopesDeployedAt si)
    reference (siPermissionsDeployedAt si)
    reference (siTreasuryDeployedAt si)
    reference (siRegistryDeployedAt si)
    withdrawScript
        (siPermissionsRewardAccount si)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    forM_ (siSwapOrders si) $ \so -> do
        let val =
                lovelaceValue
                    ( Coin $
                        unCoin (soLovelace so)
                            + unCoin
                                (siSwapOrderExtraLovelace si)
                    )
        void $
            payTo'
                (siSwapOrderAddress si)
                val
                (RawPlutusData (soDatum so))
    let leftoverValue =
            case siTreasuryLeftoverAsset si of
                Nothing ->
                    lovelaceValue
                        (siTreasuryLeftoverLovelace si)
                Just la ->
                    MaryValue
                        (siTreasuryLeftoverLovelace si)
                        ( MultiAsset $
                            Map.singleton (laPolicy la) $
                                Map.singleton
                                    (laAsset la)
                                    (laQuantity la)
                        )
    _ <- payTo (siTreasuryAddress si) leftoverValue
    forM_ (siSigners si) requireSignature
    validTo (siUpperBound si)

lovelaceValue :: Coin -> MaryValue
lovelaceValue c = MaryValue c (MultiAsset Map.empty)

{- | Static parameters shared by every swap-order datum
in a single swap tx. The scope-owner key hashes are
embedded in the order's authorised-signers list per
[`swap_order.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/swap_order.sh).
-}
data SwapOrderDatumParams = SwapOrderDatumParams
    { sodPoolId :: !ByteString
    , sodCoreOwner :: !ByteString
    , sodOpsOwner :: !ByteString
    , sodNetworkComplianceOwner :: !ByteString
    , sodMiddlewareOwner :: !ByteString
    , sodSundaeProtocolFeeLovelace :: !Integer
    , sodTreasuryScriptHash :: !ByteString
    , sodUsdmPolicy :: !ByteString
    , sodUsdmToken :: !ByteString
    }

{- | The inline 'Data' value for one swap-order chunk
mirroring the JSON literal in
[`swap_order.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/swap_order.sh).
-}
swapOrderDatum
    :: SwapOrderDatumParams
    -> Integer
    -- ^ chunk lovelace
    -> Integer
    -- ^ chunk USDM (= floor (chunk_lovelace * rate))
    -> Data
swapOrderDatum p chunkLovelace chunkUsdm =
    Constr
        0
        [ Constr 0 [B (sodPoolId p)]
        , Constr
            1
            [ List
                [ Constr 0 [B (sodCoreOwner p)]
                , Constr 0 [B (sodOpsOwner p)]
                , Constr
                    0
                    [B (sodNetworkComplianceOwner p)]
                , Constr 0 [B (sodMiddlewareOwner p)]
                ]
            ]
        , I (sodSundaeProtocolFeeLovelace p)
        , Constr
            0
            [ Constr
                0
                [ Constr
                    1
                    [B (sodTreasuryScriptHash p)]
                , Constr
                    0
                    [ Constr
                        0
                        [ Constr
                            1
                            [B (sodTreasuryScriptHash p)]
                        ]
                    ]
                ]
            , Constr 0 []
            ]
        , Constr
            1
            [ List [B "", B "", I chunkLovelace]
            , List
                [ B (sodUsdmPolicy p)
                , B (sodUsdmToken p)
                , I chunkUsdm
                ]
            ]
        , Constr 0 []
        ]
