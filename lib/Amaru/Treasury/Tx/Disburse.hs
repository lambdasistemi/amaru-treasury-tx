{- |
Module      : Amaru.Treasury.Tx.Disburse
Description : Pure TxBuild program for the @disburse@ subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`journal/2026/bin/disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh)
+
[`journal/2026/lib/build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh)
for the ADA and USDM disburse cases: single
beneficiary, leftover back to the treasury.

The intent type carries already-resolved ledger values.
'Main' is responsible for the @Text → ledger@ lift (via
'Amaru.Treasury.LedgerParse') and the UTxO selection
(via 'Amaru.Treasury.UtxoSelect').
-}
module Amaru.Treasury.Tx.Disburse
    ( -- * Intent
      DisburseIntent (..)
    , DisburseIntentFields (..)
    , DisburseAdaPayload (..)
    , DisburseUsdmPayload (..)

      -- * Program
    , disburseAdaProgram
    , disburseUsdmProgram
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (KeyHash, ScriptHash (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
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
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , disburseAdaRedeemer
    , disburseRedeemer
    , emptyListRedeemer
    )

{- | Shared resolved inputs across ADA and (later) USDM
disburse variants. The fields here describe the chain
state that does not depend on the disbursed unit.
-}
data DisburseIntentFields = DisburseIntentFields
    { difWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , difBeneficiaryAddress :: !Addr
    -- ^ payee of the disbursement
    , difTreasuryUtxos :: ![TxIn]
    -- ^ pre-selected treasury UTxOs to be spent
    , difTreasuryAddress :: !Addr
    -- ^ treasury contract address (leftover destination)
    , difPermissionsRewardAccount :: !AccountAddress
    -- ^ Amaru permissions reward account
    --   (withdraw-zero target)
    , difScopesDeployedAt :: !TxIn
    -- ^ scope-owners NFT reference UTxO
    , difPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions script reference UTxO
    , difTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury script reference UTxO
    , difRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO
    , difSigners :: ![KeyHash Guard]
    -- ^ scope owner + witness scope owners (TxBuild
    --     uses the @Guard@ role for required-signer
    --     keyhashes)
    , difUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }
    deriving stock (Show, Eq)

{- | ADA-disburse-specific payload: the lovelace amount
sent to the beneficiary and the lovelace amount returned
to the treasury as leftover.
-}
data DisburseAdaPayload = DisburseAdaPayload
    { dapAmountLovelace :: !Coin
    -- ^ amount of ADA to send to the beneficiary
    , dapLeftoverLovelace :: !Coin
    -- ^ leftover ADA returned to the treasury address
    }
    deriving stock (Show, Eq)

{- | USDM-disburse-specific payload. The amount is in
USDM's smallest unit. The beneficiary lovelace deposit
is supplied by the build runner because it depends on
the selected treasury inputs in the frozen or live
'ChainContext'; the intent carries the resulting
leftover value.
-}
data DisburseUsdmPayload = DisburseUsdmPayload
    { dupUsdmPolicy :: !PolicyID
    -- ^ USDM minting policy
    , dupUsdmAsset :: !AssetName
    -- ^ USDM asset name
    , dupAmountUsdm :: !Integer
    -- ^ USDM quantity sent to the beneficiary
    , dupLeftoverLovelace :: !Coin
    -- ^ leftover ADA returned to the treasury address
    , dupLeftoverUsdm :: !Integer
    -- ^ leftover USDM returned to the treasury address
    , dupLeftoverOtherAssets :: !MultiAsset
    -- ^ non-USDM native assets preserved on the leftover
    }
    deriving stock (Show, Eq)

{- | Resolved inputs for a disburse transaction.

Build dispatchers pattern-match on this ADT and call
the matching builder.
-}
data DisburseIntent
    = DisburseAdaIntent !DisburseIntentFields !DisburseAdaPayload
    | DisburseUsdmIntent !DisburseIntentFields !DisburseUsdmPayload
    deriving stock (Show, Eq)

{- | Build the ADA disburse transaction. Mirrors
@build_transaction.sh@: spend wallet fuel + treasury
UTxOs, attach the four reference inputs (scopes,
permissions, treasury, registry), withdraw-zero on the
permissions reward account, two outputs (leftover →
treasury, amount → beneficiary), required signers, and
the validity upper bound.

Takes the shared 'DisburseIntentFields' and the
ADA-specific 'DisburseAdaPayload' separately so the
USDM builder in T038 can share the same field record.
-}
disburseAdaProgram
    :: DisburseIntentFields
    -> DisburseAdaPayload
    -> TxBuild q e ()
disburseAdaProgram f p = do
    _ <- spend (difWalletUtxo f)
    collateral (difWalletUtxo f)
    let spendRedeemer =
            RawPlutusData $
                disburseAdaRedeemer
                    (unCoin (dapAmountLovelace p))
    forM_ (difTreasuryUtxos f) $ \txin ->
        void (spendScript txin spendRedeemer)
    reference (difScopesDeployedAt f)
    reference (difPermissionsDeployedAt f)
    reference (difTreasuryDeployedAt f)
    reference (difRegistryDeployedAt f)
    withdrawScript
        (difPermissionsRewardAccount f)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    _ <-
        payTo
            (difTreasuryAddress f)
            (lovelaceValue (dapLeftoverLovelace p))
    _ <-
        payTo
            (difBeneficiaryAddress f)
            (lovelaceValue (dapAmountLovelace p))
    forM_ (difSigners f) requireSignature
    validTo (difUpperBound f)

{- | Build the USDM disburse transaction. The operation
sequence is the same as 'disburseAdaProgram', but the
treasury redeemer and beneficiary output carry a
single native asset entry under the configured USDM
policy/token. All spent ADA, leftover USDM, and other
native assets remain on the treasury leftover output.
-}
disburseUsdmProgram
    :: DisburseIntentFields
    -> DisburseUsdmPayload
    -> Coin
    -- ^ lovelace deposit on the beneficiary output
    -> TxBuild q e ()
disburseUsdmProgram f p beneficiaryLovelace = do
    _ <- spend (difWalletUtxo f)
    collateral (difWalletUtxo f)
    let spendRedeemer =
            RawPlutusData $
                disburseRedeemer
                    (policyIdBytes (dupUsdmPolicy p))
                    (assetNameRawBytes (dupUsdmAsset p))
                    (dupAmountUsdm p)
    forM_ (difTreasuryUtxos f) $ \txin ->
        void (spendScript txin spendRedeemer)
    reference (difScopesDeployedAt f)
    reference (difPermissionsDeployedAt f)
    reference (difTreasuryDeployedAt f)
    reference (difRegistryDeployedAt f)
    withdrawScript
        (difPermissionsRewardAccount f)
        (Coin 0)
        (RawPlutusData emptyListRedeemer)
    _ <-
        payTo
            (difTreasuryAddress f)
            ( MaryValue
                (dupLeftoverLovelace p)
                ( leftoverAssets
                    (dupUsdmPolicy p)
                    (dupUsdmAsset p)
                    (dupLeftoverUsdm p)
                    (dupLeftoverOtherAssets p)
                )
            )
    _ <-
        payTo
            (difBeneficiaryAddress f)
            ( MaryValue
                beneficiaryLovelace
                (singleAsset (dupUsdmPolicy p) (dupUsdmAsset p) (dupAmountUsdm p))
            )
    forM_ (difSigners f) requireSignature
    validTo (difUpperBound f)

-- | Wrap a 'Coin' into a pure-ADA 'MaryValue'.
lovelaceValue :: Coin -> MaryValue
lovelaceValue c = MaryValue c (MultiAsset Map.empty)

singleAsset :: PolicyID -> AssetName -> Integer -> MultiAsset
singleAsset policy asset quantity =
    MultiAsset $
        normalizeAssetMap $
            Map.singleton policy $
                Map.singleton asset quantity

leftoverAssets
    :: PolicyID -> AssetName -> Integer -> MultiAsset -> MultiAsset
leftoverAssets policy asset quantity (MultiAsset otherAssets) =
    MultiAsset $
        normalizeAssetMap $
            Map.unionWith
                (Map.unionWith (+))
                otherAssets
                usdmAssets
  where
    usdmAssets
        | quantity == 0 = Map.empty
        | otherwise =
            Map.singleton policy $
                Map.singleton asset quantity

normalizeAssetMap
    :: Map.Map PolicyID (Map.Map AssetName Integer)
    -> Map.Map PolicyID (Map.Map AssetName Integer)
normalizeAssetMap =
    Map.filter (not . Map.null)
        . Map.map (Map.filter (/= 0))

policyIdBytes :: PolicyID -> ByteString
policyIdBytes (PolicyID (ScriptHash scriptHash)) =
    hashToBytes scriptHash

assetNameRawBytes :: AssetName -> ByteString
assetNameRawBytes (AssetName raw) =
    SBS.fromShort raw
