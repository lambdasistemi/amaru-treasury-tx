{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Coordinator.FeePaymentSpec
Description : Tests for coordinator fee-payment planning
License     : Apache-2.0
-}
module Amaru.Treasury.Coordinator.FeePaymentSpec (spec) where

import Data.Aeson
    ( object
    , (.=)
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Coordinator.Client
    ( FeeQuote (..)
    )
import Amaru.Treasury.Coordinator.FeePayment
    ( FeePaymentPlan (..)
    , coordinatorFeeMetadataLabel
    , planCoordinatorFeePayment
    )

spec :: Spec
spec = describe "Amaru.Treasury.Coordinator.FeePayment Coordinate" $
    it "plans the quoted address, lovelace, and body-hash metadata" $ do
        let plan = planCoordinatorFeePayment sampleQuote
        coordinatorFeeMetadataLabel `shouldBe` 9721
        fppAddress plan `shouldBe` fqFeeAddress sampleQuote
        fppLovelace plan `shouldBe` fqRequiredFeeLovelace sampleQuote
        fppMetadataLabel plan `shouldBe` 9721
        fppMetadata plan
            `shouldBe` object ["body_hash" .= fqBodyHash sampleQuote]

sampleQuote :: FeeQuote
sampleQuote =
    FeeQuote
        { fqBodyHash =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        , fqRequiredFeeLovelace = 4_200_000
        , fqFeeAddress = "addr_test1fee"
        , fqTag =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        , fqInvalidHereafter = 123_456
        }
