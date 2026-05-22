{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.TypesSpec
Description : JSON round-trips for the #239 API carriers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.TypesSpec (spec) where

import Data.Aeson (decode, encode)
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
    )
import Amaru.Treasury.Scope (ScopeId, allScopes)

spec :: Spec
spec = do
    describe "BuildIdentity JSON" $
        it "round-trips via aeson" $
            property roundTripBuildIdentity

    describe "RecentTxManifest JSON" $
        it "round-trips via aeson" $
            property roundTripRecentTxManifest

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
