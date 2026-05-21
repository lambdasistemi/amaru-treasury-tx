{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Build.GovernanceWithdrawalInitSpec
Description : Governance-withdrawal-init build runner regressions
License     : Apache-2.0
-}
module Amaru.Treasury.Build.GovernanceWithdrawalInitSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Ledger.Address
    ( AccountAddress
    , Withdrawals (..)
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , outputsTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway
    ( ApplyTxError (..)
    , ConwayEra
    )
import Cardano.Ledger.Conway.Rules (ConwayLedgerPredFailure)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Tx.Build (mkPParamsBound)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate
    ( isWitnessCompletenessFailure
    , validatePhase1WithRewardAccounts
    )
import Lens.Micro ((^.))

import Amaru.Treasury.Build
    ( runBuild
    )
import Amaru.Treasury.Build.Result (BuildResult (..))
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitMaterializationTx (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , decodeTreasuryIntentFile
    , translateIntent
    )
import Amaru.Treasury.Tx.Withdraw (WithdrawIntent (..))

spec :: Spec
spec =
    describe "governance materialization conservation" $ do
        it "balances withdrawn rewards into treasury output and wallet change" $ do
            (_, tx, buildResult) <- buildSyntheticMaterialization
            let body = brFinalTxBody buildResult
                Withdrawals withdrawals = body ^. withdrawalsTxBodyL
                outputs = toList (body ^. outputsTxBodyL)
                Coin fee = body ^. feeTxBodyL
                reward = gwimtRewardsAmount tx
                walletLovelace =
                    sum (txOutLovelace . snd <$> brWalletInputs buildResult)
                outputLovelace = sum (txOutLovelace <$> outputs)
            withdrawals
                `shouldBe` Map.singleton
                    (gwimtTreasuryRewardAccount tx)
                    reward
            case outputs of
                [treasuryOut, changeOut] -> do
                    txOutLovelace treasuryOut `shouldBe` unCoin reward
                    txOutLovelace changeOut
                        `shouldBe` walletLovelace - fee
                _ ->
                    expectationFailure
                        ( "expected treasury output plus wallet change, got "
                            <> show (length outputs)
                            <> " outputs"
                        )
            walletLovelace + unCoin reward
                `shouldBe` outputLovelace + fee
        it
            "passes reward-aware final Phase-1 validation for the synthetic materialization fixture"
            $ do
                (ctx, _, buildResult) <- buildSyntheticMaterialization
                tx <- expectRightIO (decodeFinalTx buildResult)
                assertNoStructuralPhase1Failures ctx tx

buildSyntheticMaterialization
    :: IO
        ( ChainContext
        , GovernanceWithdrawalInitMaterializationTx
        , BuildResult
        )
buildSyntheticMaterialization = do
    fixture <- readSwapFixture "test/fixtures/withdraw/synthetic"
    (shared, withdrawIntent) <- loadSyntheticWithdrawIntent
    let reward = Coin 2_000_000
        ctx = toFrozenContext fixture
        tx =
            GovernanceWithdrawalInitMaterializationTx
                { gwimtFundingAddress = tsWalletAddr shared
                , gwimtSeedTxIn =
                    wiWalletUtxo withdrawIntent
                , gwimtTreasuryRewardAccount =
                    wiTreasuryRewardAccount withdrawIntent
                , gwimtTreasuryAddress =
                    wiTreasuryAddress withdrawIntent
                , gwimtTreasuryRefTxIn =
                    wiTreasuryDeployedAt withdrawIntent
                , gwimtRegistryRefTxIn =
                    wiRegistryDeployedAt withdrawIntent
                , gwimtRewardsAmount = reward
                , gwimtUpperBoundSlot =
                    wiUpperBound withdrawIntent
                }
    buildResult <-
        runBuild
            ctx
            shared{tsNetwork = "devnet"}
            SGovernanceWithdrawalInitMaterialization
            tx
    pure (ctx, tx, buildResult)

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

loadSyntheticWithdrawIntent
    :: IO (TranslatedShared, WithdrawIntent)
loadSyntheticWithdrawIntent = do
    some <-
        expectRightIO
            =<< decodeTreasuryIntentFile
                "test/fixtures/withdraw/synthetic/intent.json"
    case some of
        SomeTreasuryIntent SWithdraw intent ->
            expectRightIO (translateIntent SWithdraw intent)
        _ -> do
            expectationFailure "expected withdraw synthetic intent"
            error "unreachable"

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOut ^. valueTxOutL
    in  lovelace

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure
