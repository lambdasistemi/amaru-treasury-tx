{- |
Module      : UsdmDisburseGoldenSpec
Description : Body-CBOR golden for USDM disburse (skeleton)
License     : Apache-2.0
-}
module UsdmDisburseGoldenSpec (spec) where

import Test.Hspec (Spec, describe, it, pendingWith)

spec :: Spec
spec =
    describe "usdm-disburse" $
        it "skeleton — golden lands in phase 5 (T041–T044)" $
            pendingWith "phase 5 placeholder"
