{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.WithdrawSpec
Description : Withdraw build runner regressions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.WithdrawSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    )

import Cardano.Ledger.Address (AccountAddress, Withdrawals (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body (withdrawalsTxBodyL)
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    )
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway
    ( ApplyTxError (..)
    , ConwayEra
    )
import Cardano.Ledger.Conway.Rules (ConwayLedgerPredFailure)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Tx.Build (mkPParamsBound)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate
    ( isWitnessCompletenessFailure
    , validatePhase1WithRewardAccounts
    )
import Lens.Micro ((^.))

import Amaru.Treasury.Build (BuildResult (..), runFromIntent)
import Amaru.Treasury.ChainContext
    ( ChainContext (..)
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON (decodeTreasuryIntentFile)

spec :: Spec
spec =
    describe "Amaru.Treasury.Build.Withdraw"
        $ it
            "passes reward-aware final Phase-1 validation for the synthetic withdraw fixture"
        $ do
            some <-
                expectRightIO
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/withdraw/synthetic/intent.json"
            fixture <- readSwapFixture "test/fixtures/withdraw/synthetic"
            let ctx = toFrozenContext fixture
            result <- runFromIntent ctx some
            tx <- expectRightIO (decodeFinalTx result)
            assertNoStructuralPhase1Failures ctx tx

decodeFinalTx :: BuildResult -> Either String ConwayTx
decodeFinalTx result =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (brCborBytes result) of
        Right tx -> Right tx
        Left err -> Left (show err)

assertNoStructuralPhase1Failures :: ChainContext -> ConwayTx -> IO ()
assertNoStructuralPhase1Failures ctx tx =
    case validatePhase1WithRewardAccounts
        (ccNetwork ctx)
        (mkPParamsBound (ccPParams ctx))
        (Map.toList (ccUtxos ctx))
        (withdrawalRewardAccounts tx)
        (ccTipSlot ctx)
        tx of
        Right () -> pure ()
        Left err -> do
            let structural =
                    filter
                        (not . isWitnessCompletenessFailure)
                        (phase1Failures err)
            if null structural
                then pure ()
                else
                    expectationFailure $
                        "structural Phase-1 failures: "
                            <> show structural

withdrawalRewardAccounts :: ConwayTx -> Map.Map AccountAddress Coin
withdrawalRewardAccounts tx =
    let Withdrawals withdrawals = tx ^. bodyTxL . withdrawalsTxBodyL
    in  withdrawals

phase1Failures
    :: ApplyTxError ConwayEra
    -> [ConwayLedgerPredFailure ConwayEra]
phase1Failures (ConwayApplyTxError errs) = toList errs

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure
