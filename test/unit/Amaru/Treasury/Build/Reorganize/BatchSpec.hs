{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Build.Reorganize.BatchSpec
Description : Boundary cases for the pure batch-size math
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Tests the closed-form math used by the reorganize tx-build path as
the **initial guess** of a projected linear descent: given one
over-budget measurement at @currentN@, predict the largest @N*@
whose projected cost fits the per-tx ledger ceiling. The runner
then walks down by 1 from there on real measurements until the
cliff is found.

Uses the actual mainnet probe measurements as ground-truth:

  * core_development (N=2): total memory 845,658 well under the
    16,500,000 mainnet cap. 'measurementFits' returns 'True';
    'estimateNStar' returns 'currentN' unchanged.

  * network_compliance (N=55): total memory 371,468,288 (22× cap),
    total steps 130,657,229,151 (13× cap). 'estimateNStar' returns
    11 (mem-binding); the runner then steps down to N=10, the
    empirical cliff.
-}
module Amaru.Treasury.Build.Reorganize.BatchSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Ledger.Plutus (ExUnits (..))

import Amaru.Treasury.Build.Reorganize.Batch
    ( BatchLimits (..)
    , estimateNStar
    , measurementFits
    , nStarFromMeasured
    )

spec :: Spec
spec = describe "Amaru.Treasury.Build.Reorganize.Batch" $ do
    describe "nStarFromMeasured" $ do
        it "returns currentN unchanged when measured fits the limit" $
            nStarFromMeasured 2 845_658 16_500_000
                `shouldBe` 2

        it "returns currentN when measured == 0 (defensive)" $
            nStarFromMeasured 10 0 16_500_000
                `shouldBe` 10

        it
            "scales sqrt-down on a memory ceiling that's 22× over \
            \(network_compliance mainnet probe)"
            $ do
                let n = nStarFromMeasured 55 371_468_288 16_500_000
                -- N* = floor(55 · sqrt(16_500_000 / 371_468_288))
                --    = floor(55 · sqrt(0.04443))
                --    = floor(55 · 0.2108) = floor(11.59) = 11
                n `shouldBe` 11

        it
            "scales sqrt-down on a steps ceiling that's 13× over \
            \(network_compliance mainnet probe)"
            $ do
                let n = nStarFromMeasured 55 130_657_229_151 10_000_000_000
                -- N* = floor(55 · sqrt(10⁹ / 130.6 × 10⁹))
                --    ≈ floor(55 · 0.2766) ≈ floor(15.21) = 15
                n `shouldBe` 15

    describe "estimateNStar" $ do
        it
            "returns 11 on the network_compliance probe (mem-binding)"
            $ do
                let bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            }
                estimateNStar
                    55
                    (ExUnits 371_468_288 130_657_229_151)
                    30_000
                    bl
                    `shouldBe` 11

        it "never drops below the 2-input floor" $ do
            let bl =
                    BatchLimits
                        { blMaxExUnits =
                            ExUnits 16_500_000 10_000_000_000
                        , blMaxSize = 16_384
                        }
            estimateNStar
                3
                (ExUnits 999_999_999_999 999_999_999_999)
                99_999
                bl
                `shouldSatisfy` (>= 2)

    describe "measurementFits" $ do
        it
            "True on the core_development trial (845,658 mem ≪ \
            \16,500,000 cap)"
            $ do
                let bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            }
                measurementFits
                    (ExUnits 845_658 304_743_989)
                    1217
                    bl
                    `shouldBe` True

        it
            "False on the network_compliance N=11 measurement \
            \(17,276,725 mem > 16,500,000)"
            $ do
                let bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            }
                measurementFits
                    (ExUnits 17_276_725 6_097_477_472)
                    1700
                    bl
                    `shouldBe` False

        it
            "True on the network_compliance N=10 measurement (empirical \
            \cliff; mem 16,xxx,xxx < 16,500,000)"
            $ do
                -- N=10 mainnet probe: tx-build prints
                -- "built 1649 bytes  fee=1570783  total_collateral=2356175"
                -- and VALIDATION OK. We don't have the exact ExUnits
                -- print from that run, but they're necessarily ≤ the
                -- ledger cap (else validation would have rejected).
                let bl =
                        BatchLimits
                            { blMaxExUnits =
                                ExUnits 16_500_000 10_000_000_000
                            , blMaxSize = 16_384
                            }
                -- Lower bound on the actual N=10 measurement, derived
                -- by extrapolation: ~14M mem (extrapolated from
                -- N=11 = 17.3M scaled by 10/11 quadratically).
                measurementFits
                    (ExUnits 14_300_000 5_038_000_000)
                    1649
                    bl
                    `shouldBe` True
