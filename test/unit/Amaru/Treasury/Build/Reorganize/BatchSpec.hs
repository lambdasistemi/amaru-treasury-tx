{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Build.Reorganize.BatchSpec
Description : Boundary cases for the pure batch-size scaler
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Tests the closed-form math used by the reorganize tx-build path to
pick the largest @N*@-input batch that fits the per-tx exec-unit and
size ceilings. Uses the actual mainnet measurements observed on the
#218 / #230 probe runs as ground-truth boundary cases:

  * core_development (N=2): total memory 845,658 well under the
    16,500,000 mainnet cap. The scaler should return 'BatchKeep'.

  * network_compliance (N=55): total memory 371,468,288 (22× cap),
    total steps 130,657,229,151 (13× cap). The scaler should pick
    a small @N*@ — concretely around 11–13 once the safety factor
    is applied.
-}
module Amaru.Treasury.Build.Reorganize.BatchSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Ledger.Plutus (ExUnits (..))

import Amaru.Treasury.Build.Reorganize.Batch
    ( BatchDecision (..)
    , BatchInputs (..)
    , BatchLimits (..)
    , decideBatch
    , nStarFromMeasured
    )

spec :: Spec
spec = describe "Amaru.Treasury.Build.Reorganize.Batch" $ do
    describe "nStarFromMeasured" $ do
        it "returns currentN unchanged when measured fits the limit" $
            nStarFromMeasured
                2
                845_658
                16_500_000
                0.85
                `shouldBe` 2

        it "returns currentN when measured == 0 (defensive)" $
            nStarFromMeasured
                10
                0
                16_500_000
                0.85
                `shouldBe` 10

        it
            "scales sqrt-down on a memory ceiling that's 22× over \
            \(network_compliance mainnet probe)"
            $ do
                let n =
                        nStarFromMeasured
                            55
                            371_468_288
                            16_500_000
                            0.85
                -- N* = floor(55 · sqrt(0.85 · 16,500,000 / 371,468,288))
                --    = floor(55 · sqrt(0.03774…))
                --    = floor(55 · 0.1943…) = floor(10.687…)
                --    = 10
                n `shouldBe` 10

        it
            "scales sqrt-down on a steps ceiling that's 13× over \
            \(network_compliance mainnet probe)"
            $ do
                let n =
                        nStarFromMeasured
                            55
                            130_657_229_151
                            10_000_000_000
                            0.85
                -- N* = floor(55 · sqrt(0.85 · 10⁹ / 130.6×10⁹))
                --    ≈ floor(55 · 0.2554…) = floor(14.05…) = 14
                n `shouldBe` 14

        it "respects the safety alpha (smaller alpha → smaller N*)" $ do
            let nLoose =
                    nStarFromMeasured
                        55
                        371_468_288
                        16_500_000
                        1.0
                nTight =
                    nStarFromMeasured
                        55
                        371_468_288
                        16_500_000
                        0.50
            nLoose `shouldSatisfy` (> nTight)

    describe "decideBatch" $ do
        it
            "returns BatchKeep when the trial already fits all three \
            \dimensions (core_development mainnet probe)"
            $ do
                let bi =
                        BatchInputs
                            { biMeasuredCost =
                                ExUnits 845_658 304_743_989
                            , biMeasuredSize = 1217
                            , biCurrentN = 2
                            }
                    bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            , blSafetyAlpha = 0.85
                            }
                decideBatch bi bl `shouldBe` BatchKeep

        it
            "truncates on the binding (memory) dimension when the \
            \trial overflows (network_compliance mainnet probe)"
            $ do
                let bi =
                        BatchInputs
                            { biMeasuredCost =
                                ExUnits 371_468_288 130_657_229_151
                            , biMeasuredSize = 30_000
                            , biCurrentN = 55
                            }
                    bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            , blSafetyAlpha = 0.85
                            }
                -- Mem-bound: 10; steps-bound: 14; size-bound:
                -- floor(55 · 0.85 · 16384/30000) = floor(25.5) = 25.
                -- Binding minimum: 10.
                decideBatch bi bl `shouldBe` BatchTruncateTo 10

        it
            "never truncates below 2 even on a pathological \
            \over-budget"
            $ do
                let bi =
                        BatchInputs
                            { biMeasuredCost =
                                ExUnits 999_999_999_999 999_999_999_999
                            , biMeasuredSize = 99_999
                            , biCurrentN = 3
                            }
                    bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            , blSafetyAlpha = 0.85
                            }
                decideBatch bi bl `shouldBe` BatchTruncateTo 2
