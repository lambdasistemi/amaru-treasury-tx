{- |
Module      : Amaru.Treasury.Registry.MetadataSpec
Description : Tests for local registry metadata parsing
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Registry.MetadataSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Registry.Metadata
    ( RegistryWalkError (..)
    , UpstreamMetadata (..)
    , decodeUpstreamMetadata
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Registry.Metadata" $ do
        it "parses the checked-in local metadata fixture" $ do
            result <-
                readUpstreamMetadataFile
                    "test/fixtures/registry-walk/metadata.json"
            case result of
                Right metadata ->
                    Map.member CoreDevelopment (umTreasuries metadata)
                        `shouldBe` True
                Left err ->
                    fail ("metadata fixture did not parse: " <> show err)

        it "reports unreadable local metadata files as typed errors" $ do
            result <-
                readUpstreamMetadataFile
                    "test/fixtures/registry-walk/missing.json"
            result `shouldSatisfy` isReadError

        it "reports invalid JSON as MetadataParse" $
            decodeUpstreamMetadata "{"
                `shouldSatisfy` isParseError

isReadError :: Either RegistryWalkError UpstreamMetadata -> Bool
isReadError = \case
    Left MetadataReadError{} -> True
    _ -> False

isParseError :: Either RegistryWalkError UpstreamMetadata -> Bool
isParseError = \case
    Left MetadataParse{} -> True
    _ -> False
