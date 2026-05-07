{- |
Module      : WithdrawGoldenSpec
Description : Scaffolding for the withdraw CBOR golden
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module WithdrawGoldenSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "withdraw golden" $
        it "scaffolding compiles" $
            (1 + 1 :: Int) `shouldBe` 2
