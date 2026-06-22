{- |
Module      : Amaru.Treasury.Swap.Rerate.BudgetSpec
Description : Unit tests for pure swap re-rate budget planning
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the pure budget planner that decides whether a validated re-rate
selection fits in one transaction or must be split into stable
caller-order groups, with the computed total estimate and reason.
-}
module Amaru.Treasury.Swap.Rerate.BudgetSpec (spec) where

import Cardano.Ledger.Api.PParams
    ( PParams
    , emptyPParams
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Plutus (ExUnits (..))
import Data.Word (Word32)
import Lens.Micro ((&), (.~))
import Numeric.Natural (Natural)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Swap.Rerate.Budget
    ( planRerate
    , planRerateWithBudget
    )
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerateOrder
    , RerateBudgetEstimate (..)
    , RerateBudgetModel (..)
    , ReratePlan (..)
    , ReratePlanReason (..)
    , RerateSplit (..)
    )

pparams :: Natural -> Natural -> Word32 -> PParams ConwayEra
pparams maxMem maxSteps maxSize =
    emptyPParams
        & ppMaxTxExUnitsL .~ ExUnits maxMem maxSteps
        & ppMaxTxSizeL .~ maxSize

budgetEstimate
    :: Natural
    -> Natural
    -> Int
    -> RerateBudgetEstimate
budgetEstimate memory steps size =
    RerateBudgetEstimate
        { rbeMemory = memory
        , rbeSteps = steps
        , rbeSize = size
        }

budgetModel
    :: RerateBudgetEstimate
    -> RerateBudgetEstimate
    -> RerateBudgetModel
budgetModel base perOrder =
    RerateBudgetModel
        { rbmBaseEstimate = base
        , rbmPerOrderEstimate = perOrder
        }

spec :: Spec
spec = describe "Amaru.Treasury.Swap.Rerate.Budget" $ do
    it "keeps the public planner on planned orders plus pparams" $ do
        case planRerate
            ([] :: [PlannedRerateOrder])
            (pparams 1_000_000 1_000_000_000 2000) of
            SingleTx reason _ orders -> do
                reason `shouldBe` RerateWithinBudget
                orders `shouldBe` []
            Split{} ->
                expectationFailure "empty public plan unexpectedly split"

    it "selects SingleTx when estimates fit all limits" $ do
        let orders = [1 :: Int, 2, 3]
            model =
                budgetModel
                    (budgetEstimate 10 50 20)
                    (budgetEstimate 10 100 20)
            pp = pparams 100 1000 500
        planRerateWithBudget model orders pp
            `shouldBe` SingleTx
                RerateWithinBudget
                (budgetEstimate 40 350 80)
                orders

    it "selects Split when one order is over the memory limit" $ do
        let orders = [1 :: Int]
            model =
                budgetModel
                    (budgetEstimate 10 50 20)
                    (budgetEstimate 5 100 20)
            pp = pparams 14 1000 500
        planRerateWithBudget model orders pp
            `shouldBe` Split
                RerateOverExecutionMemory
                (budgetEstimate 15 150 40)
                [ RerateSplit
                    { rsOrders = orders
                    , rsCreatesReplacement = True
                    }
                ]

    it "splits pathological large selections into stable fitting groups" $ do
        let orders = [1 :: Int .. 10]
            model =
                budgetModel
                    (budgetEstimate 0 0 5)
                    (budgetEstimate 1 1 10)
            pp = pparams 1000 1000 35
        planRerateWithBudget model orders pp
            `shouldBe` Split
                RerateOverTxSize
                (budgetEstimate 10 10 105)
                [ RerateSplit
                    { rsOrders = [1, 2, 3]
                    , rsCreatesReplacement = False
                    }
                , RerateSplit
                    { rsOrders = [4, 5, 6]
                    , rsCreatesReplacement = False
                    }
                , RerateSplit
                    { rsOrders = [7, 8, 9]
                    , rsCreatesReplacement = False
                    }
                , RerateSplit
                    { rsOrders = [10]
                    , rsCreatesReplacement = True
                    }
                ]

    it "keeps exact-limit estimates in a SingleTx" $ do
        let orders = [1 :: Int .. 4]
            model =
                budgetModel
                    (budgetEstimate 1 10 1)
                    (budgetEstimate 1 5 1)
            pp = pparams 1000 30 1000
        planRerateWithBudget model orders pp
            `shouldBe` SingleTx
                RerateWithinBudget
                (budgetEstimate 5 30 5)
                orders
