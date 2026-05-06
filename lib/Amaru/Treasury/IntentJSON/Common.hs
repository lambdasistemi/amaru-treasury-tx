{- |
Module      : Amaru.Treasury.IntentJSON.Common
Description : Shared parser helpers for the unified intent (skeleton)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Placeholder skeleton for feature 005 phase 2 (T008). The
shared parser helpers ('parseAddr', 'parseTxIn',
'parseRewardAccount', 'parseGuardKeyHash',
'decodeHexBytes', 'mkHash28', 'mkHash32') will move here
verbatim from
'Amaru.Treasury.Tx.SwapIntentJSON' once T008 lands. The
existing copies in that module are deleted in T011 (a
partial delete, leaving the SwapIntentJSON record + its
translateIntent body for T021's borrowing).
-}
module Amaru.Treasury.IntentJSON.Common
    (
    ) where
