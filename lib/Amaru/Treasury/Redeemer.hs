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

* @reorganizeRedeemer@ — Sundae @TreasurySpendRedeemer.Reorganize@,
  constructor 0, empty fields. Mirrors
  [`make_redeemer_reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_reorganize.sh).

* @emptyListRedeemer@ — empty list, used as the redeemer
  for the Amaru permissions withdraw-zero entry on every
  @disburse@/@reorganize@ tx, and for the treasury
  withdrawal in @withdraw@.
-}
module Amaru.Treasury.Redeemer
    ( -- * Sundae treasury-spend redeemers
      disburseAdaRedeemer
    , disburseRedeemer
    , reorganizeRedeemer

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

{- | @Constr 0 []@ — Sundae @Reorganize@.

Identical to @make_redeemer_reorganize.sh@: the variant
carries no fields and the bash literal pins constructor
index 0.
-}
reorganizeRedeemer :: Data
reorganizeRedeemer = Constr 0 []

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
