{- |
Module      : Amaru.Treasury.ScopeSpec
Description : Round-trip tests for 'Amaru.Treasury.Scope'
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.ScopeSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Scope
    ( allScopes
    , scopeFromText
    , scopeText
    )

spec :: Spec
spec = describe "Amaru.Treasury.Scope" $ do
    it "parses every canonical scope name" $ do
        traverse (scopeFromText . scopeText) allScopes
            `shouldBe` Right allScopes

    it "rejects an unknown scope name" $ do
        scopeFromText "core development"
            `shouldBe` Left
                "unknown scope: core development; expected one of \
                \[\"core_development\",\"ops_and_use_cases\",\
                \\"network_compliance\",\"middleware\",\"contingency\"]"
