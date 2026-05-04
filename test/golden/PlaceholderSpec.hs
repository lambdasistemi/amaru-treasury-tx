{- |
Module      : PlaceholderSpec
Description : Placeholder golden-test spec to keep the suite non-empty
License     : Apache-2.0
-}
module PlaceholderSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "golden harness" $ do
    it "scaffolding compiles" $ do
        (1 + 1 :: Int) `shouldBe` 2
