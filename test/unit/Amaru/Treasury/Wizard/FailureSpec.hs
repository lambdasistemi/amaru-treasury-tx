{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.FailureSpec
Description : Unit tests for 'WizardFailure' / 'BuildFailure'
              typed-failure surface (#259).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Wizard.FailureSpec
    ( spec
    ) where

import Data.Aeson (decode, encode)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T

import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    , FieldId (..)
    , WizardFailure (..)
    , fieldOf
    , fieldOfBuild
    , isInput
    , isInputBuild
    , renderBuildFailure
    , renderWizardFailure
    )

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Failure" $ do
    describe "FieldId" $ do
        it "encodes FieldScope as \"scope\"" $
            encode FieldScope `shouldBe` "\"scope\""
        it "decodes \"wallet_addr\" as FieldWalletAddr" $
            decode "\"wallet_addr\"" `shouldBe` Just FieldWalletAddr
        it "round-trips every constructor" $
            mapM_
                ( \f -> decode (encode f) `shouldBe` Just f
                )
                allFieldIds

    describe "WizardFailure" $ do
        describe "renderWizardFailure" $
            it "returns non-empty text for every sample variant" $
                mapM_
                    ( \f ->
                        renderWizardFailure f `shouldSatisfy` (not . T.null)
                    )
                    sampleWizardFailures

        describe "isInput / fieldOf agreement" $ do
            it "every Input* sample has isInput True" $
                mapM_
                    (\f -> isInput f `shouldBe` True)
                    inputWizardFailures
            it "every non-Input sample has isInput False" $
                mapM_
                    (\f -> isInput f `shouldBe` False)
                    nonInputWizardFailures
            it "Input* samples have a field" $
                mapM_
                    (\f -> fieldOf f `shouldSatisfy` isJust)
                    inputWizardFailures
            it "non-Input samples have no field" $
                mapM_
                    (\f -> fieldOf f `shouldSatisfy` isNothing)
                    nonInputWizardFailures

    describe "BuildFailure" $ do
        describe "renderBuildFailure" $
            it "returns non-empty text for every sample variant" $
                mapM_
                    ( \f ->
                        renderBuildFailure f `shouldSatisfy` (not . T.null)
                    )
                    sampleBuildFailures

        describe "isInputBuild / fieldOfBuild agreement" $ do
            it "every Input* sample has isInputBuild True" $
                mapM_
                    (\f -> isInputBuild f `shouldBe` True)
                    inputBuildFailures
            it "non-Input samples have no field" $
                mapM_
                    (\f -> fieldOfBuild f `shouldSatisfy` isNothing)
                    nonInputBuildFailures

-- ---------------------------------------------------------------------------
-- Samples covering each variant of the failure types. New variants must
-- be added here so the smoke test covers them; the broader coverage gate
-- (#259 Phase 5) is layered on top of this.

allFieldIds :: [FieldId]
allFieldIds =
    [ FieldScope
    , FieldWalletAddr
    , FieldUsdm
    , FieldAllAda
    , FieldSplit
    , FieldRate
    , FieldSlippageBps
    , FieldValidityHours
    , FieldDescription
    , FieldJustification
    , FieldDestinationLabel
    , FieldEvent
    , FieldLabel
    , FieldExtraSigner
    , FieldMetadataPath
    , FieldExcludeUtxo
    , FieldForceUtxo
    ]

inputWizardFailures :: [WizardFailure]
inputWizardFailures =
    [ InputInvalid FieldWalletAddr "bech32 decode failed"
    , InputOutOfRange FieldValidityHours "must be > 0"
    , InputControl FieldExcludeUtxo "exclude ∩ force"
    , InputScopeUnsupported FieldScope "contingency is not supported"
    ]

nonInputWizardFailures :: [WizardFailure]
nonInputWizardFailures =
    [ ResolveNetworkUnsupported "no profile matches magic 12345"
    , ResolveSwapParameters "derive rate failed: ..."
    , ResolveRegistryVerify "verify: missing tenant"
    , ResolveResolver
        "wallet shortfall: 4_500_000 available, 7_200_000 required"
    , ResolveValidityHorizon "validity-hours overshoots chain horizon"
    , InternalTranslate "translate: ChunkSizeBelowMinUtxo"
    , InternalEncodeError "intent encoding failed"
    ]

sampleWizardFailures :: [WizardFailure]
sampleWizardFailures = inputWizardFailures <> nonInputWizardFailures

inputBuildFailures :: [BuildFailure]
inputBuildFailures =
    [ BuildInputInvalid FieldScope "scope mismatch"
    ]

nonInputBuildFailures :: [BuildFailure]
nonInputBuildFailures =
    [ BuildResolveParams "pparams fetch failed"
    , BuildResolveTip "tip query failed"
    , BuildResolveUtxo "missing tx#0"
    , BuildBuildError "TxBuild refused: min-utxo violation"
    , BuildInternalError "invariant: report row mismatch"
    ]

sampleBuildFailures :: [BuildFailure]
sampleBuildFailures = inputBuildFailures <> nonInputBuildFailures
