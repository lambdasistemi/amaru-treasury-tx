{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.TypesSpec
Description : JSON round-trips for the #239 API carriers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime (..)
    , fromGregorian
    , secondsToDiffTime
    )
import Test.Hspec (Spec, describe, it)
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , Property
    , elements
    , forAll
    , listOf
    , oneof
    , property
    , vectorOf
    )

import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , BuildIdentity (..)
    , RecentTxEntry (..)
    , RecentTxManifest (..)
    , ScopeHistoryEntry (..)
    , ScopeHistoryResponse (..)
    , TxDetailInput (..)
    , TxDetailOutput (..)
    , TxDetailResponse (..)
    )
import Amaru.Treasury.Inspect.SwapOrderProjection
    ( ProjectedSwapOrder (..)
    )
import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedAsset (..)
    , ProjectedTreasurySpend (..)
    )
import Amaru.Treasury.Report.Accounting (ValueSummary (..))
import Amaru.Treasury.Scope (ScopeId, allScopes)

spec :: Spec
spec = do
    describe "BuildIdentity JSON" $
        it "round-trips via aeson" $
            property roundTripBuildIdentity

    describe "RecentTxManifest JSON" $
        it "round-trips via aeson" $
            property roundTripRecentTxManifest

    describe "ScopeHistoryResponse JSON" $
        it "round-trips via aeson" $
            property roundTripScopeHistoryResponse

    describe "TxDetailResponse JSON" $
        it "round-trips via aeson" $
            property roundTripTxDetailResponse

    describe "ApiError JSON" $
        it "round-trips via aeson with and without aeField" $
            property roundTripApiError

-- ---------------------------------------------------------------------------
-- Properties

roundTripBuildIdentity :: Property
roundTripBuildIdentity =
    forAll genBuildIdentity $ \bi ->
        decode (encode bi) == Just bi

roundTripRecentTxManifest :: Property
roundTripRecentTxManifest =
    forAll genRecentTxManifest $ \m ->
        decode (encode m) == Just m

roundTripScopeHistoryResponse :: Property
roundTripScopeHistoryResponse =
    forAll genScopeHistoryResponse $ \r ->
        decode (encode r) == Just r

roundTripTxDetailResponse :: Property
roundTripTxDetailResponse =
    forAll genTxDetailResponse $ \r ->
        decode (encode r) == Just r

roundTripApiError :: Property
roundTripApiError =
    forAll genApiError $ \e ->
        decode (encode e) == Just e

-- ---------------------------------------------------------------------------
-- Generators

genBuildIdentity :: Gen BuildIdentity
genBuildIdentity =
    BuildIdentity
        <$> genUTCTime
        <*> genShortText
        <*> genHex64
        <*> genShortText
        <*> (arbitrary :: Gen Int)

genRecentTxManifest :: Gen RecentTxManifest
genRecentTxManifest = RecentTxManifest <$> listOf genRecentTxEntry

genRecentTxEntry :: Gen RecentTxEntry
genRecentTxEntry =
    RecentTxEntry
        <$> genScope
        <*> genHex64
        <*> genUTCTime
        <*> genShortText

genScopeHistoryResponse :: Gen ScopeHistoryResponse
genScopeHistoryResponse =
    ScopeHistoryResponse
        <$> genScope
        <*> listOf genScopeHistoryEntry

genScopeHistoryEntry :: Gen ScopeHistoryEntry
genScopeHistoryEntry =
    ScopeHistoryEntry
        <$> arbitrary
        <*> genHex64
        <*> genShortText
        <*> elements ["outbound", "inbound"]

genTxDetailResponse :: Gen TxDetailResponse
genTxDetailResponse =
    TxDetailResponse
        <$> arbitrary
        <*> genHex64
        <*> genShortText
        <*> genShortText
        <*> elements ["outbound", "inbound"]
        <*> oneof [pure Nothing, Just <$> genHex64]
        <*> oneof [pure Nothing, Just <$> arbitrary]
        <*> listOf genShortText
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> listOf genProjectedTreasurySpend
        <*> listOf genTxDetailInput
        <*> listOf genTxDetailOutput
        <*> listOf genShortText

genProjectedTreasurySpend :: Gen ProjectedTreasurySpend
genProjectedTreasurySpend =
    ProjectedTreasurySpend
        <$> elements
            ["Reorganize", "SweepTreasury", "Fund", "Disburse"]
        <*> listOf genProjectedAsset

genProjectedAsset :: Gen ProjectedAsset
genProjectedAsset =
    ProjectedAsset
        <$> genShortText
        <*> genShortText
        <*> arbitrary

genTxDetailInput :: Gen TxDetailInput
genTxDetailInput =
    TxDetailInput
        <$> genShortText
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> oneof [pure Nothing, Just <$> genValueSummary]
        <*> arbitrary

genTxDetailOutput :: Gen TxDetailOutput
genTxDetailOutput =
    TxDetailOutput
        <$> arbitrary
        <*> genShortText
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> genValueSummary
        <*> oneof [pure Nothing, Just <$> genShortText]
        <*> oneof [pure Nothing, Just <$> genProjectedSwapOrder]

genProjectedSwapOrder :: Gen ProjectedSwapOrder
genProjectedSwapOrder =
    ProjectedSwapOrder
        <$> genShortText
        <*> genProjectedAsset
        <*> arbitrary

genValueSummary :: Gen ValueSummary
genValueSummary =
    ValueSummary
        <$> arbitrary
        <*> (Map.fromList <$> listOf genAssetEntry)

genAssetEntry :: Gen (Text, Map Text Integer)
genAssetEntry =
    (,)
        <$> genShortText
        <*> ( Map.fromList
                <$> listOf ((,) <$> genShortText <*> arbitrary)
            )

genApiError :: Gen ApiError
genApiError =
    ApiError
        <$> genShortText
        <*> oneof [pure Nothing, Just <$> genShortText]

genScope :: Gen ScopeId
genScope = elements allScopes

genShortText :: Gen Text
genShortText = fmap T.pack (listOf (elements ['a' .. 'z']))

genHex64 :: Gen Text
genHex64 =
    fmap T.pack (vectorOf 64 (elements "0123456789abcdef"))

genUTCTime :: Gen UTCTime
genUTCTime = do
    d <-
        fromGregorian 2026
            <$> elements [1 .. 12]
            <*> elements [1 .. 28]
    s <- elements [0, 7200, 43200, 86399]
    pure $ UTCTime d (secondsToDiffTime s)
