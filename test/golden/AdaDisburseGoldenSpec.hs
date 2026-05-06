{- |
Module      : AdaDisburseGoldenSpec
Description : Body-CBOR golden for ADA disburse (skeleton)
License     : Apache-2.0
-}
module AdaDisburseGoldenSpec (spec) where

import Test.Hspec (Spec, describe, it, pendingWith)

spec :: Spec
spec =
    describe "ada-disburse" $
        it "skeleton — golden lands in phase 4 (T030–T033)" $
            pendingWith "phase 4 placeholder"
