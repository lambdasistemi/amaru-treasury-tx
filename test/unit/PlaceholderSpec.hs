{- |
Module      : PlaceholderSpec
Description : Placeholder unit-test spec to keep the suite non-empty
License     : Apache-2.0
-}
module PlaceholderSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "amaru-treasury-tx" $ do
    it "scaffolding compiles" $ do
        (1 + 1 :: Int) `shouldBe` 2
