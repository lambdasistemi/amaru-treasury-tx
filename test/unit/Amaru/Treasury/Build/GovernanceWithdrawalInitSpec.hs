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

import Cardano.Ledger.Address (Withdrawals (..))
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , outputsTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Lens.Micro ((^.))

import Amaru.Treasury.Build
    ( runBuild
    )
import Amaru.Treasury.Build.Result (BuildResult (..))
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
    describe "governance materialization conservation" $
        it "balances withdrawn rewards into treasury output and wallet change" $ do
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
            let body = brFinalTxBody buildResult
                Withdrawals withdrawals = body ^. withdrawalsTxBodyL
                outputs = toList (body ^. outputsTxBodyL)
                Coin fee = body ^. feeTxBodyL
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
