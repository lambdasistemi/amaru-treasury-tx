{- |
Module      : Amaru.Treasury.Backend
Description : Alias around Cardano.Node.Client.Provider
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The CLI consumes the existing
[`Cardano.Node.Client.Provider`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/Provider.hs)
record-of-functions interface as its sole effect-y
boundary. We re-export it under the
@Amaru.Treasury.Backend@ name so callers in this
project don't have to reach into @cardano-node-clients@
directly.

Backend implementations live under
@Amaru.Treasury.Backend.*@. The default and only
implementation in MVP is @Amaru.Treasury.Backend.N2C@
(local cardano-node socket).
-}
module Amaru.Treasury.Backend
    ( -- * Alias
      Backend

      -- * Re-exports from cardano-node-clients
    , Provider (..)
    , EvaluateTxResult
    , SlotNo (..)
    ) where

import Cardano.Node.Client.Provider
    ( EvaluateTxResult
    , Provider (..)
    , SlotNo (..)
    )

-- | The CLI's effect-y boundary: a 'Provider' running in 'IO'.
type Backend = Provider IO
