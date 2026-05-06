{- |
Module      : Amaru.Treasury.Tx.DisburseIntentJSON
Description : JSON contract for the disburse intent (skeleton)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Placeholder skeleton for feature 004 phase 1. The
'DisburseIntentJSON' record, its 'FromJSON'/'ToJSON'
instances, the stable encoder, and the
@decodeDisburseIntent@/@translateDisburseIntent@ pair
land in phase 2 (T007 + T009). Adding the module to the
library now keeps the cabal stanza honest and lets
downstream test stubs import the module name even before
its types exist.
-}
module Amaru.Treasury.Tx.DisburseIntentJSON
    (
    ) where
