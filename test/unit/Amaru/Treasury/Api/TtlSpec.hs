{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.TtlSpec
Description : Built-tx RDF Turtle lattice tests (#357)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.TtlSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Api.Ttl (buildTxLattice)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Api.Ttl" $ do
        it "emits body Turtle from a fixture unsigned tx hex" $ do
            hex <- fixtureHex
            result <- buildTxLattice Nothing hex
            case result of
                Just ttl ->
                    shouldContainAll
                        ttl
                        [ "@prefix cardano:"
                        , "a cardano:Transaction"
                        ]
                Nothing ->
                    expectationFailure
                        "expected Turtle, got Nothing"

        it "overlays metadata entities onto the body graph" $ do
            hex <- fixtureHex
            md <- loadMetadata
            result <- buildTxLattice (Just md) hex
            case result of
                Just ttl ->
                    shouldContainAll
                        ttl
                        [ "a cardano:Entity"
                        , "atx:scope \"core_development\""
                        ]
                Nothing ->
                    expectationFailure
                        "expected Turtle, got Nothing"

        it "returns Nothing on undecodable hex" $ do
            result <- buildTxLattice Nothing "zz-not-hex"
            result `shouldBe` Nothing

{- | Unsigned Conway tx hex in the exact form the build
responses carry in their @CborHex@ field.
-}
fixtureHex :: IO Text
fixtureHex =
    T.strip
        <$> TIO.readFile
            "test/fixtures/118-vault-witness/unsigned.cbor.hex"

loadMetadata :: IO TreasuryMetadata
loadMetadata = readMetadataFile "test/fixtures/metadata.json"

shouldContainAll :: Text -> [Text] -> IO ()
shouldContainAll haystack =
    mapM_
        ( \needle ->
            (needle, needle `T.isInfixOf` haystack)
                `shouldBe` (needle, True)
        )
