{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Build.CommonSpec
Description : Shared build helper regressions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.CommonSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Withdrawals (..))
import Cardano.Ledger.Alonzo.TxBody (scriptIntegrityHashTxBodyL)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( withdrawalsTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((&), (.~), (^.))

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.Build.Common (validateFinalPhase1)
import Amaru.Treasury.ChainContext (ChainContext)
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON (decodeTreasuryIntentFile)

spec :: Spec
spec =
    describe "validateFinalPhase1" $ do
        it
            "rejects structural failures on withdrawal-bearing final transactions"
            $ do
                (ctx, tx) <-
                    buildFinalTx
                        "test/fixtures/withdraw/synthetic"
                        "test/fixtures/withdraw/synthetic/intent.json"
                withdrawalCount tx `shouldSatisfy` (> 0)
                shouldRejectStructurally
                    ctx
                    (dropScriptIntegrityHash tx)

        it "accepts missing vkey witnesses as signing-step noise" $ do
            (ctx, tx) <-
                buildFinalTx
                    "test/fixtures/withdraw/synthetic"
                    "test/fixtures/withdraw/synthetic/intent.json"
            validateFinalPhase1 ctx tx `shouldBe` Right ()

        it "rejects non-witness structural ledger failures" $ do
            (ctx, tx) <-
                buildFinalTx
                    "test/fixtures/withdraw/synthetic"
                    "test/fixtures/withdraw/synthetic/intent.json"
            shouldRejectStructurally
                ctx
                (dropScriptIntegrityHash (withoutWithdrawals tx))

buildFinalTx :: FilePath -> FilePath -> IO (ChainContext, ConwayTx)
buildFinalTx fixtureDir intentPath = do
    some <- expectRightIO =<< decodeTreasuryIntentFile intentPath
    fixture <- readSwapFixture fixtureDir
    let ctx = toFrozenContext fixture
    result <- runFromIntent ctx some
    tx <- expectRightIO (decodeFinalTx result)
    pure (ctx, tx)

decodeFinalTx :: BuildResult -> Either String ConwayTx
decodeFinalTx result =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (brCborBytes result) of
        Right tx -> Right tx
        Left err -> Left (show err)

dropScriptIntegrityHash :: ConwayTx -> ConwayTx
dropScriptIntegrityHash tx =
    tx & bodyTxL . scriptIntegrityHashTxBodyL .~ SNothing

withoutWithdrawals :: ConwayTx -> ConwayTx
withoutWithdrawals tx =
    tx & bodyTxL . withdrawalsTxBodyL .~ Withdrawals Map.empty

withdrawalCount :: ConwayTx -> Int
withdrawalCount tx =
    let Withdrawals withdrawals = tx ^. bodyTxL . withdrawalsTxBodyL
    in  length withdrawals

shouldRejectStructurally :: ChainContext -> ConwayTx -> IO ()
shouldRejectStructurally ctx tx =
    case validateFinalPhase1 ctx tx of
        Left msg ->
            msg
                `shouldSatisfy` T.isInfixOf
                    "Phase-1 validation rejected final transaction"
        Right () ->
            expectationFailure
                "expected validateFinalPhase1 to reject a structural failure"

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure
