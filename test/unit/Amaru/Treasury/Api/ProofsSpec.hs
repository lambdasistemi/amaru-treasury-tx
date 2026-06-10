{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.ProofsSpec
Description : SPARQL proof suite over the built-tx graph (#358)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.ProofsSpec (spec) where

import Data.Foldable (for_)
import Data.List (elemIndex, find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldNotBe
    )

import Amaru.Treasury.Api.Proofs
    ( ProofResult (..)
    , runBuildProofs
    )
import Amaru.Treasury.Api.Ttl (resolvedInputTurtle)
import Amaru.Treasury.ChainContext.Fixture
    ( SwapFixture (..)
    , readSwapFixture
    )
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Api.Proofs" $ do
        it "emits resolved-input values in the body vocabulary" $ do
            fixture <- readSwapFixture "test/fixtures/swap"
            let ttl = resolvedInputTurtle (sfUtxos fixture)
            shouldContainAll
                ttl
                [ "<urn:cardano:utxo:" <> scopesNftTxId <> ":0>"
                , "a cardano:Output"
                , "cardano:lovelace"
                , "cardano:hasAssetValue"
                , "<urn:cardano:id:AssetClass:" <> scopesAssetHex <> ">"
                , "cardano:leafType \"AssetClass\""
                , "cardano:quantity 1"
                , "cardano:bech32"
                ]

        it "runs the three named proofs over a balanced fixture" $ do
            md <- loadMetadata
            fixture <- readSwapFixture "test/fixtures/swap"
            hex <- fixtureCborHex
            let resolver txIns =
                    pure (Map.restrictKeys (sfUtxos fixture) txIns)
            result <- runBuildProofs (Just md) resolver hex
            case result of
                Nothing ->
                    expectationFailure
                        "expected proof results, got Nothing"
                Just proofs -> do
                    prName <$> proofs
                        `shouldBe` [ "value-conservation"
                                   , "recipient-resolution"
                                   , "datum-redeemer"
                                   ]
                    for_ proofs $ \p ->
                        (prName p, prColumns p)
                            `shouldNotBe` (prName p, [])
                    checkValueConservation proofs
                    checkRecipients proofs
                    checkDatumRedeemer proofs

        it "returns Nothing on undecodable hex" $ do
            result <-
                runBuildProofs
                    Nothing
                    (\_ -> pure Map.empty)
                    "zz-not-hex"
            result `shouldBe` Nothing

{- | Every per-asset row of the value-conservation proof must
report @balanced = true@ on a fixture built by the real
builder against its own UTxO set.
-}
checkValueConservation :: [ProofResult] -> IO ()
checkValueConservation proofs =
    case find ((== "value-conservation") . prName) proofs of
        Nothing ->
            expectationFailure "no value-conservation proof"
        Just p -> do
            prRows p `shouldNotBe` []
            case elemIndex "balanced" (prColumns p) of
                Nothing ->
                    expectationFailure
                        ( "no balanced column in "
                            <> show (prColumns p)
                        )
                Just ix ->
                    for_ (prRows p) $ \row ->
                        (row, row !! ix) `shouldBe` (row, "true")

{- | The swap pays back into the swap-scope treasury, so at
least one output row must resolve to a treasury scope, and
every row carries a non-empty scope (known or @external@).
-}
checkRecipients :: [ProofResult] -> IO ()
checkRecipients proofs =
    case find ((== "recipient-resolution") . prName) proofs of
        Nothing ->
            expectationFailure "no recipient-resolution proof"
        Just p -> do
            prRows p `shouldNotBe` []
            case elemIndex "scope" (prColumns p) of
                Nothing ->
                    expectationFailure
                        ( "no scope column in "
                            <> show (prColumns p)
                        )
                Just ix -> do
                    let scopes = (!! ix) <$> prRows p
                    filter (/= "external") scopes
                        `shouldNotBe` []
                    filter T.null scopes `shouldBe` []

{- | The swap fixture carries inline order datums and spend +
withdraw redeemers; both kinds must surface as rows.
-}
checkDatumRedeemer :: [ProofResult] -> IO ()
checkDatumRedeemer proofs =
    case find ((== "datum-redeemer") . prName) proofs of
        Nothing ->
            expectationFailure "no datum-redeemer proof"
        Just p ->
            case elemIndex "kind" (prColumns p) of
                Nothing ->
                    expectationFailure
                        ( "no kind column in "
                            <> show (prColumns p)
                        )
                Just ix -> do
                    let kinds = (!! ix) <$> prRows p
                    filter (== "datum") kinds `shouldNotBe` []
                    filter (== "redeemer") kinds
                        `shouldNotBe` []

{- | Unsigned Conway tx hex in the exact form the build
responses carry in their @CborHex@ field; the fixture file
already stores the tx as hex text.
-}
fixtureCborHex :: IO Text
fixtureCborHex =
    T.strip <$> TIO.readFile "test/fixtures/swap/expected.cbor"

loadMetadata :: IO TreasuryMetadata
loadMetadata = readMetadataFile "test/fixtures/metadata.json"

-- | Source tx of the scope-owners NFT UTxO in the swap fixture.
scopesNftTxId :: Text
scopesNftTxId =
    "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54"

{- | @policy <> asset-name@ hex of the @amaru 2026 scopes@ NFT,
the identifier scheme @cq-rdf@ uses for @AssetClass@ leaves.
-}
scopesAssetHex :: Text
scopesAssetHex =
    "5a7350fef97581498697d679aa1cbc4fb72f51991bde8ad535614365"
        <> "616d61727520323032362073636f706573"

shouldContainAll :: Text -> [Text] -> IO ()
shouldContainAll haystack =
    mapM_
        ( \needle ->
            (needle, needle `T.isInfixOf` haystack)
                `shouldBe` (needle, True)
        )
