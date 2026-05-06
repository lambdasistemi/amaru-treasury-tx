{- |
Module      : Amaru.Treasury.Tx.Reorganize
Description : Placeholder typed intent for the reorganize action
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Skeleton placeholder. The real 'ReorganizeIntent' shape — the
typed lift consumed by the reorganize build path — lands with
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46).

This module exists so the @Translated 'Reorganize@ row of the
type family in
[`Amaru.Treasury.IntentJSON`](Amaru.Treasury.IntentJSON.html)
can name a concrete type on this branch. Mirrors the existing
[`Amaru.Treasury.Tx.Withdraw`](Amaru.Treasury.Tx.Withdraw.html)
which already exposes a typed @WithdrawIntent@.
-}
module Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    ) where

-- | Placeholder. Real shape lands with #46.
data ReorganizeIntent = ReorganizeIntent
    deriving stock (Eq, Show)
