{- |
Module      : Amaru.Treasury.Swap.Rerate.Budget
Description : Pure budget planner for swap re-rate transactions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Chooses whether a validated re-rate selection should be attempted as
one transaction or represented as stable split groups before any body is
built. The planner is pure: it reads protocol limits from supplied
parameters and applies a linear fixed-plus-per-order estimate.
-}
module Amaru.Treasury.Swap.Rerate.Budget
    ( defaultRerateBudgetModel
    , planRerate
    , planRerateWithBudget
    ) where

import Cardano.Ledger.Api.PParams
    ( PParams
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Plutus (ExUnits (..))
import Data.Word (Word32)
import Lens.Micro ((^.))
import Numeric.Natural (Natural)

import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerateOrder
    , RerateBudgetEstimate (..)
    , RerateBudgetModel (..)
    , ReratePlan (..)
    , ReratePlanReason (..)
    , RerateSplit (..)
    )

-- | Initial linear estimator used by the public planner.
defaultRerateBudgetModel :: RerateBudgetModel
defaultRerateBudgetModel =
    RerateBudgetModel
        { rbmBaseEstimate =
            RerateBudgetEstimate
                { rbeMemory = 500_000
                , rbeSteps = 100_000_000
                , rbeSize = 900
                }
        , rbmPerOrderEstimate =
            RerateBudgetEstimate
                { rbeMemory = 1_300_000
                , rbeSteps = 500_000_000
                , rbeSize = 450
                }
        }

{- | Plan a re-rate selection against protocol parameters.

This is the public planner surface: callers provide already validated
planned orders and the Conway protocol parameters, and receive a typed
single-transaction or split decision.
-}
planRerate
    :: [PlannedRerateOrder]
    -> PParams ConwayEra
    -> ReratePlan PlannedRerateOrder
planRerate =
    planRerateWithBudget defaultRerateBudgetModel

{- | Plan with an explicit linear budget model.

This helper keeps the core decision small and directly testable while
'planRerate' remains the production-facing API over protocol
parameters.
-}
planRerateWithBudget
    :: RerateBudgetModel
    -> [order]
    -> PParams ConwayEra
    -> ReratePlan order
planRerateWithBudget model orders pp =
    let limits = limitsFromPParams pp
        total = estimateForCount model (length orders)
        reason = planReason limits total
    in  if reason == RerateWithinBudget
            then SingleTx reason total orders
            else Split reason total (splitGroups model limits orders)

data BudgetLimits = BudgetLimits
    { blMemory :: !Natural
    , blSteps :: !Natural
    , blSize :: !Int
    }

limitsFromPParams :: PParams ConwayEra -> BudgetLimits
limitsFromPParams pp =
    let ExUnits maxMemory maxSteps = pp ^. ppMaxTxExUnitsL
    in  BudgetLimits
            { blMemory = maxMemory
            , blSteps = maxSteps
            , blSize =
                fromIntegral
                    (pp ^. ppMaxTxSizeL :: Word32)
            }

planReason
    :: BudgetLimits
    -> RerateBudgetEstimate
    -> ReratePlanReason
planReason limits estimate
    | rbeMemory estimate > blMemory limits =
        RerateOverExecutionMemory
    | rbeSteps estimate > blSteps limits =
        RerateOverExecutionSteps
    | rbeSize estimate > blSize limits =
        RerateOverTxSize
    | otherwise = RerateWithinBudget

splitGroups
    :: RerateBudgetModel
    -> BudgetLimits
    -> [order]
    -> [RerateSplit order]
splitGroups model limits =
    markFinal . go
  where
    go [] = []
    go remaining =
        let n = fittingPrefixLength model limits remaining
            here = take n remaining
            rest = drop n remaining
        in  RerateSplit
                { rsOrders = here
                , rsCreatesReplacement = False
                }
                : go rest

markFinal :: [RerateSplit order] -> [RerateSplit order]
markFinal [] = []
markFinal [group] = [group{rsCreatesReplacement = True}]
markFinal (group : groups) =
    group{rsCreatesReplacement = False} : markFinal groups

fittingPrefixLength
    :: RerateBudgetModel
    -> BudgetLimits
    -> [order]
    -> Int
fittingPrefixLength model limits orders =
    case takeWhile
        ( \n ->
            planReason limits (estimateForCount model n)
                == RerateWithinBudget
        )
        [1 .. length orders] of
        [] -> 1
        fitting -> last fitting

estimateForCount
    :: RerateBudgetModel
    -> Int
    -> RerateBudgetEstimate
estimateForCount model n =
    addEstimate
        (rbmBaseEstimate model)
        (scaleEstimate n (rbmPerOrderEstimate model))

addEstimate
    :: RerateBudgetEstimate
    -> RerateBudgetEstimate
    -> RerateBudgetEstimate
addEstimate left right =
    RerateBudgetEstimate
        { rbeMemory = rbeMemory left + rbeMemory right
        , rbeSteps = rbeSteps left + rbeSteps right
        , rbeSize = rbeSize left + rbeSize right
        }

scaleEstimate :: Int -> RerateBudgetEstimate -> RerateBudgetEstimate
scaleEstimate n estimate =
    RerateBudgetEstimate
        { rbeMemory = factor * rbeMemory estimate
        , rbeSteps = factor * rbeSteps estimate
        , rbeSize = n * rbeSize estimate
        }
  where
    factor = fromIntegral n
