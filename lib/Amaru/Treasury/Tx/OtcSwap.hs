{- |
Module      : Amaru.Treasury.Tx.OtcSwap
Description : Atomic OTC swap — named asset in, ADA out, one spend
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Issue #499. A single treasury spend that sends ADA to a counterparty
and receives a named asset into the treasury, atomically: either both
legs settle or neither does.

The authorization is one @Disburse@ redeemer carrying a positive
lovelace entry and a __negative__ asset entry ('otcSwapRedeemer'). The
pinned treasury validator checks
@equal_plus_min_ada (merge input_sum (negate amount)) output_sum@
over treasury-addressed UTxOs only, so a negative entry in @amount@
obliges the continuing treasury output to carry that much more of the
asset — that is the whole mechanism.

Three parties appear, and their roles are deliberately distinct:

* the __treasury__ gives ADA and receives the asset;
* the __counterparty__ supplies the asset and receives the ADA, and
  supplies nothing else;
* the __operator__ supplies fuel and collateral, and pays the fee.

Collateral is forfeited when phase 2 fails, and phase 2 here runs the
treasury's own validator — so the operator carries it, never the
counterparty (spec FR-004a). The builder itself is funding-agnostic:
it spends whatever 'DisburseIntentFields' field
'difWalletUtxo' names and uses it as collateral. Which UTxO __should__
play that role is a selection policy and lives upstream (slice D).
The byte-exact golden builds the on-chain reference arrangement,
which is counterparty-funded; the operator-funded properties are
asserted separately.

The counterparty is __not__ a member of the treasury multisig: their
signature is required by the ledger because their UTxO is spent,
which is a different claim from 'difSigners' (spec INV-7).

== The inline unit datum on the treasury output

The treasury continuing output is emitted with an __inline unit
datum__ (@Constr 0 []@, serialised @d87980@) via @payTo'@. This
differs deliberately from the neighbouring disburse builders, which
emit a bare @payTo@. Ruling (ticket inbox-05): T-B04 is byte-exactness
against a transaction the validator accepted, and the accepted body
carries the datum — the counterparty's SundaeSwap offchain tooling
emits @lockAssets(…, Data.Void())@ and an OTC swap is inherently
two-sided, so matching their shape keeps the two sides byte-comparable
when diffing proposals before signing. The validator ignores datums
(@treasury.ak@: "The datum is always ignored") and prohibits only a
datum __hash__, never an inline datum. Do not drop this datum to
match the disburse neighbour.

Peer of "Amaru.Treasury.Tx.Disburse"; it deliberately does not import
its programs. The shared reference-input and withdraw-zero preamble
is duplicated on purpose: the disburse path is live on mainnet and
extracting a preamble now would modify it under a feature that has
never run.
-}
module Amaru.Treasury.Tx.OtcSwap
    ( -- * Intent
      OtcSwapIntent (..)
    , OtcSwapPayload (..)

      -- * Builder
    , otcSwapProgram
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
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

import Cardano.Ledger.Address (Addr)
import Cardano.Tx.Build
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

import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    , otcSwapRedeemer
    )
import Amaru.Treasury.Tx.Disburse (DisburseIntentFields (..))

import PlutusCore.Data (Data (..))

{- | OTC-swap-specific payload.

Every quantity is stated the way an operator states the trade:
'ospIncomingQuantity' is __positive__ and the sign is a property of
the redeemer encoding alone. 'ospCounterpartyLovelace' is the
lovelace carried by the counterparty output — the ADA leg plus
whatever of their own lovelace the arrangement routes through this
output (the on-chain reference routes none of it; their lovelace
cycles through fuel\/collateral and balancing instead). The
counterparty's asset remainder rides 'ospCounterpartyLeftover'; a
remainder not routed here reaches the change address through
balancing.
-}
data OtcSwapPayload = OtcSwapPayload
    { ospCounterpartyAddress :: !Addr
    -- ^ destination of the ADA leg
    , ospCounterpartyUtxo :: !TxIn
    -- ^ counterparty UTxO supplying the incoming asset. Spent, so
    --   the counterparty must witness the transaction — a ledger
    --   requirement, not treasury-multisig membership.
    , ospCounterpartyLeftover :: !MultiAsset
    -- ^ asset remainder returned to the counterparty
    , ospCounterpartyLovelace :: !Coin
    -- ^ lovelace on the counterparty output. Never fee-deducted
    --   (spec INV-5).
    , ospAdaOut :: !Coin
    -- ^ lovelace leaving the treasury
    , ospIncomingPolicy :: !PolicyID
    -- ^ incoming asset policy; supplied by the operator, never a
    --   compile-time constant (spec FR-007)
    , ospIncomingAsset :: !AssetName
    -- ^ incoming asset name
    , ospIncomingQuantity :: !Integer
    -- ^ incoming quantity, positive
    , ospLeftoverLovelace :: !Coin
    -- ^ ADA retained on the treasury continuing output
    , ospLeftoverAssets :: !MultiAsset
    -- ^ the treasury's pre-existing native assets, preserved in full
    }
    deriving stock (Eq, Show)

-- | Resolved inputs for an OTC swap.
data OtcSwapIntent
    = OtcSwapIntent !DisburseIntentFields !OtcSwapPayload
    deriving stock (Eq, Show)

{- | The inline unit datum (@Constr 0 []@) the treasury continuing
output carries; see the module header for the ruling.
-}
unitDatum :: RawPlutusData
unitDatum = RawPlutusData (Constr 0 [])

{- | Build the OTC swap transaction.

1. spend the fuel UTxO and use it as collateral;
2. spend the counterparty UTxO supplying the incoming asset;
3. spend each treasury UTxO under the two-legged @Disburse@ redeemer;
4. attach the scopes, permissions, treasury and registry references;
5. withdraw zero against the permissions reward account;
6. pay the counterparty output first — the ADA leg plus their routed
   remainder — matching the accepted body's output order;
7. pay the treasury its retained ADA, its pre-existing assets, __and__
   the incoming quantity, under the inline unit datum;
8. require the scope-owner signatures and set the validity bound.

The @invalidBefore@ bound is set by 'Amaru.Treasury.Build.OtcSwap'
from the sampled chain tip, exactly as the reference body does.

Unlike the USDM disburse builder this program needs no @peek@: the
counterparty output's lovelace is known up front
('ospCounterpartyLovelace'), so nothing depends on a previous build
iteration's min-UTxO compensation.
-}
otcSwapProgram
    :: DisburseIntentFields
    -> OtcSwapPayload
    -> TxBuild q e ()
otcSwapProgram f p = do
    -- Fuel and collateral. Pure-ADA collateral is a selection policy
    -- upstream (spec INV-6); the builder only reuses difWalletUtxo.
    _ <- spend (difWalletUtxo f)
    collateral (difWalletUtxo f)
    -- The counterparty's contribution: the incoming asset, nothing else.
    _ <- spend (ospCounterpartyUtxo p)
    let spendRedeemer =
            RawPlutusData $
                otcSwapRedeemer
                    (policyIdBytes (ospIncomingPolicy p))
                    (assetNameRawBytes (ospIncomingAsset p))
                    (ospIncomingQuantity p)
                    (unCoin (ospAdaOut p))
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
    -- Counterparty output first (output 0 on the accepted body): the
    -- ADA leg plus their routed remainder.
    _ <-
        payTo
            (ospCounterpartyAddress p)
            ( MaryValue
                (ospCounterpartyLovelace p)
                (ospCounterpartyLeftover p)
            )
    -- Treasury continuing output (output 1 on the accepted body):
    -- retained ADA, every pre-existing asset, plus the incoming
    -- quantity (spec INV-2, INV-3), under the inline unit datum.
    _ <-
        payTo'
            (difTreasuryAddress f)
            ( MaryValue
                (ospLeftoverLovelace p)
                ( addAsset
                    (ospIncomingPolicy p)
                    (ospIncomingAsset p)
                    (ospIncomingQuantity p)
                    (ospLeftoverAssets p)
                )
            )
            unitDatum
    forM_ (difSigners f) requireSignature
    validTo (difUpperBound f)

{- | Add @quantity@ of one asset to an existing bundle.

Zero quantities and emptied policies are dropped so the encoded value
is canonical; a zero incoming leg cannot reach here, being rejected
upstream as RJ-001.
-}
addAsset
    :: PolicyID -> AssetName -> Integer -> MultiAsset -> MultiAsset
addAsset policy asset quantity (MultiAsset existing) =
    MultiAsset $
        normalizeAssetMap $
            Map.unionWith
                (Map.unionWith (+))
                existing
                (Map.singleton policy (Map.singleton asset quantity))

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
