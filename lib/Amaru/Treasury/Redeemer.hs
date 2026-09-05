{- |
Module      : Amaru.Treasury.Redeemer
Description : Plutus-data redeemers for the Sundae and
              Amaru permissions validators
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Hand-written Plutus 'Data' values that match the bash
recipes byte-for-byte:

* @disburseRedeemer@ — Sundae @TreasurySpendRedeemer.Disburse@,
  constructor 3, single-asset map. Mirrors
  [`make_redeemer_disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_disburse.sh).

* @disburseUsdmRedeemer@ — Sundae @TreasurySpendRedeemer.Disburse@,
  constructor 3, carrying both USDM and the lovelace released
  from the treasury for the beneficiary output's min-UTxO.

* @otcSwapRedeemer@ — Sundae @TreasurySpendRedeemer.Disburse@,
  constructor 3, carrying a positive lovelace leg leaving the treasury
  and a __negative__ asset leg entering it. This is the atomic OTC
  swap (issue #499).

* @reorganizeRedeemer@ — Sundae @TreasurySpendRedeemer.Reorganize@,
  constructor 0, empty fields. Mirrors
  [`make_redeemer_reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_reorganize.sh).

* @emptyListRedeemer@ — empty list, used as the redeemer
  for the Amaru permissions withdraw-zero entry on every
  @disburse@/@reorganize@ tx, and for the treasury
  withdrawal in @withdraw@.

* @sundaeCancelRedeemer@ — SundaeSwap V3 order @Cancel@,
  constructor 1, empty fields.
-}
module Amaru.Treasury.Redeemer
    ( -- * Sundae treasury-spend redeemers
      disburseAdaRedeemer
    , disburseRedeemer
    , disburseUsdmRedeemer
    , otcSwapRedeemer
    , reorganizeRedeemer

      -- * SundaeSwap order redeemers
    , sundaeCancelRedeemer

      -- * Permissions / withdraw redeemer
    , emptyListRedeemer

      -- * 'ToData'-compatible wrapper
    , RawPlutusData (..)
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

{- | @Constr 3 [Map [(B policy, Map [(B asset, I qty)])]]@.

For an ADA disbursement, both @policy@ and @asset@ are
the empty bytestring.
-}
disburseRedeemer
    :: ByteString
    -- ^ minting-policy id (28 bytes for native; @\"\"@ for ADA)
    -> ByteString
    -- ^ asset name (variable bytes; @\"\"@ for ADA)
    -> Integer
    -- ^ quantity (lovelace for ADA, smallest unit otherwise)
    -> Data
disburseRedeemer policy asset qty =
    Constr
        3
        [ Map
            [
                ( B policy
                , Map [(B asset, I qty)]
                )
            ]
        ]

-- | Convenience for ADA disbursements: empty policy + empty asset.
disburseAdaRedeemer :: Integer -> Data
disburseAdaRedeemer = disburseRedeemer "" ""

{- | USDM disbursement redeemer including the lovelace released from
the treasury for the beneficiary output's min-UTxO.

The pinned Sundae treasury validator subtracts the redeemer @amount@
from the treasury inputs and requires the remaining treasury outputs
to match non-ADA assets exactly while only allowing additional ADA on
the treasury output. A USDM-only redeemer therefore cannot authorize
treasury ADA to leave for the beneficiary output deposit.
-}
disburseUsdmRedeemer
    :: ByteString
    -- ^ USDM minting-policy id
    -> ByteString
    -- ^ USDM asset name
    -> Integer
    -- ^ USDM quantity
    -> Integer
    -- ^ lovelace quantity released for beneficiary min-UTxO
    -> Data
disburseUsdmRedeemer policy asset qty lovelace =
    Constr
        3
        [ Map
            [ (B "", Map [(B "", I lovelace)])
            , (B policy, Map [(B asset, I qty)])
            ]
        ]

{- | Atomic OTC swap redeemer (issue #499): lovelace leaves the
treasury while a named asset enters it, authorized by one
@Disburse@ spend.

The validator checks
@equal_plus_min_ada (merge input_sum (negate amount)) output_sum@ over
treasury-addressed UTxOs only. A __negative__ entry in @amount@
therefore obliges the continuing treasury output to carry that much
more of the asset — which is exactly how the incoming leg is
authorized.

@incomingQuantity@ is taken __positive__, matching how an operator
states the trade and how the intent records it; this function is the
only place the sign is flipped. The encoder is total and assumes a
positive quantity; rejecting non-positive input is an
input-validation concern (RJ-001), not an encoder concern.

Pinned against mainnet transaction
@9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1@,
whose spend redeemer serializes to

@d87c9fa240a1401a02d69be7581cc48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ada1480014df105553444d3a0098967fff@
-}
otcSwapRedeemer
    :: ByteString
    -- ^ incoming asset's minting-policy id
    -> ByteString
    -- ^ incoming asset name
    -> Integer
    -- ^ incoming quantity, supplied positive; negated here
    -> Integer
    -- ^ lovelace leaving the treasury for the counterparty
    -> Data
otcSwapRedeemer policy asset incomingQuantity =
    disburseUsdmRedeemer policy asset (negate incomingQuantity)

{- | @Constr 0 []@ — Sundae @Reorganize@.

Identical to @make_redeemer_reorganize.sh@: the variant
carries no fields and the bash literal pins constructor
index 0.
-}
reorganizeRedeemer :: Data
reorganizeRedeemer = Constr 0 []

{- | @Constr 1 []@ — SundaeSwap V3 @OrderRedeemer.Cancel@.

The SDK encodes this value as CBOR hex @d87a80@.
-}
sundaeCancelRedeemer :: Data
sundaeCancelRedeemer = Constr 1 []

{- | @List []@ — empty redeemer.

Used for both:

* the Amaru permissions withdraw-zero entry on
  @disburse@/@reorganize@ transactions, and

* the treasury withdrawal (rewards → contract) on
  @withdraw@ transactions.

Both validator paths ignore their redeemer; an empty
list is the canonical form chosen by the bash recipes.
-}
emptyListRedeemer :: Data
emptyListRedeemer = List []

{- | A 'PlutusCore.Data.Data' value with a 'ToData'
instance. Use to pass our hand-written redeemers to the
@cardano-node-clients@ TxBuild combinators that expect
@ToData r => r@.
-}
newtype RawPlutusData = RawPlutusData {getRawPlutusData :: Data}

instance ToData RawPlutusData where
    toBuiltinData (RawPlutusData d) = BuiltinData d
