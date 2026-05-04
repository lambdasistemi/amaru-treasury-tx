{- |
Module      : Amaru.Treasury.MetadataSpec
Description : Parser test against the checked-in fixture
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.MetadataSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    , readMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , allScopes
    )

fixturePath :: FilePath
fixturePath = "test/fixtures/metadata.json"

spec :: Spec
spec = describe "Amaru.Treasury.Metadata" $ do
    it "parses every scope from the journal/2026 fixture" $ do
        m <- readMetadataFile fixturePath
        Map.keys (tmTreasuries m) `shouldBe` allScopes

    it "decodes the scope_owners reference UTxO" $ do
        m <- readMetadataFile fixturePath
        tmScopeOwners m
            `shouldBe` "11ace24a7b0caad4a68a38ef2fff181\
                       \85dc9ea604e84425dab487cae94e4cf54#00"

    it "exposes the network_compliance treasury hash" $ do
        m <- readMetadataFile fixturePath
        let nc = tmTreasuries m Map.! NetworkCompliance
        srHash (smTreasury nc)
            `shouldBe` "32201dc1e82708364c6c42a53f89f675\
                       \314bb9ad5da2734aa10baa0d"

    it "parses the contingency owner as Nothing" $ do
        m <- readMetadataFile fixturePath
        let c = tmTreasuries m Map.! Contingency
        smOwner c `shouldBe` Nothing
