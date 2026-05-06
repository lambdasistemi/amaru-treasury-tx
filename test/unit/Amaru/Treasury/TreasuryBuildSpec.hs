{- |
Module      : Amaru.Treasury.TreasuryBuildSpec
Description : Unit tests for the unified build pipeline (skeleton)
License     : Apache-2.0
-}
module Amaru.Treasury.TreasuryBuildSpec (spec) where

import Test.Hspec (Spec, describe, it, pendingWith)

spec :: Spec
spec =
    describe "Amaru.Treasury.TreasuryBuild"
        $ it
            "skeleton — network mismatch + dispatcher tests land in phases 4 + 5"
        $ pendingWith
            "phase 4 (T021) + phase 5 (T031) placeholder"
