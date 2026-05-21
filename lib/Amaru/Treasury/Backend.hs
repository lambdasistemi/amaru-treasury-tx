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
    , rewardAccountLovelace

      -- * Re-exports from cardano-node-clients
    , Provider (..)
    , QueryHandle
    , queryUTxOsAtH
    , queryUTxOByTxInH
    , queryRewardAccountsH
    , singleShotWithAcquired
    , EvaluateTxResult
    , SlotNo (..)
    ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Cardano.Ledger.Address (AccountAddress)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Node.Client.Provider
    ( EvaluateTxResult
    , Provider (..)
    , QueryHandle
    , SlotNo (..)
    , queryRewardAccountsH
    , queryUTxOByTxInH
    , queryUTxOsAtH
    , singleShotWithAcquired
    )

-- | The CLI's effect-y boundary: a 'Provider' running in 'IO'.
type Backend = Provider IO

{- | Query one reward account through a 'Provider'.

Missing rows are treated as zero rewards, matching the
@cardano-cli query stake-address-info@ no-output contract for
unregistered or empty reward accounts.
-}
rewardAccountLovelace
    :: (Functor m)
    => Provider m
    -> AccountAddress
    -> m Integer
rewardAccountLovelace provider account =
    toLovelace
        <$> queryRewardAccounts
            provider
            (Set.singleton account)
  where
    toLovelace rewards =
        let Coin lovelace =
                Map.findWithDefault
                    (Coin 0)
                    account
                    rewards
        in  lovelace
