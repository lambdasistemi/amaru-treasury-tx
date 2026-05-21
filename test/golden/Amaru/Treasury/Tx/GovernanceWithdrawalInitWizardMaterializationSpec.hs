{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardMaterializationSpec
Description : CBOR-parity golden for governance-withdrawal-init-wizard materialization
License     : Apache-2.0

Slice 3 of #160. The wizard produces a 'SomeTreasuryIntent'
from typed 'GovernanceWithdrawalInitMaterializationAnswers'
+ 'GovernanceWithdrawalInitMaterializationEnv'; that intent
— round-tripped through the @tx-build@ dispatcher
('Amaru.Treasury.Build.runFromIntent') — must produce CBOR
byte-identical to what 'buildGovernanceWithdrawalMaterializationCore'
emits from the same underlying fixture after the materialization
runner's withdrawal-to-change and fee-alignment post-processing.

Unlike the proposal arm, we do NOT compare the wizard's
in-memory intent against 'gwifIntent fixture' byte-for-byte:
the library fixture re-uses the proposal's
'placeholderScopeJSON' (whose @*DeployedAt@ slots reference
the proposal seed TxIn), while the wizard's materialization
scope is derived from the materialization-seed inputs.
The translator does NOT consume @scope.*DeployedAt@ slots,
so the resulting CBOR is identical — that is the contract
this golden pins.

Set @UPDATE_GOLDENS=1@ to rewrite the canonical fixture
under @test/fixtures/governance-withdrawal-init-wizard/@.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardMaterializationSpec
    ( spec
    ) where

import Control.Monad (unless)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    )
import Amaru.Treasury.Build.Withdraw
    ( addWithdrawalToChange
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( buildGovernanceWithdrawalMaterializationCore
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitMaterializationTx (..)
    , SomeTreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( governanceWithdrawalInitMaterializationToIntent
    )

import Support.GovernanceWithdrawalInitFixtures
    ( GovernanceWithdrawalInitFixture (..)
    , materializationFixture
    , writeIntentFile
    )
import Support.GovernanceWithdrawalInitWizardFixtures
    ( materializationIntentFixturePath
    , materializationWizardFixture
    )

spec :: Spec
spec =
    describe
        "governance-withdrawal-init-wizard materialization CBOR parity"
        $ it
            "wizard intent CBOR equals \
            \adjusted buildGovernanceWithdrawalMaterializationCore CBOR"
            materializationParity

materializationParity :: IO ()
materializationParity = do
    fixture <- materializationFixture
    let (answers, env) = materializationWizardFixture fixture
    intent <-
        case governanceWithdrawalInitMaterializationToIntent env answers of
            Left e ->
                error
                    ( "governanceWithdrawalInitMaterializationToIntent \
                      \failed: "
                        <> show e
                    )
            Right i -> pure i
    materializeOrLoadIntent materializationIntentFixturePath intent
    intentCbor <-
        intentDrivenCbor
            materializationIntentFixturePath
            (gwifContext fixture)
    let tx = gwifTranslated fixture
        ctx = gwifContext fixture
        [seedUtxo, treasuryRefUtxo, registryRefUtxo] =
            gwifInputUtxos fixture
    coreResult <-
        buildGovernanceWithdrawalMaterializationCore
            (ccPParams ctx)
            (gwimtFundingAddress tx)
            (gwimtTreasuryRewardAccount tx)
            (gwimtTreasuryAddress tx)
            (gwimtTreasuryRefTxIn tx)
            (gwimtRegistryRefTxIn tx)
            (gwimtRewardsAmount tx)
            (gwimtUpperBoundSlot tx)
            seedUtxo
            treasuryRefUtxo
            registryRefUtxo
            (frozenEvaluator ctx)
    adjustedCoreCbor <-
        expectAdjustedMaterializationCoreCbor
            "governance-withdrawal-init-materialization"
            tx
            ctx
            [treasuryRefUtxo, registryRefUtxo]
            coreResult
    intentCbor `shouldBe` adjustedCoreCbor

materializeOrLoadIntent
    :: FilePath -> SomeTreasuryIntent -> IO ()
materializeOrLoadIntent path some = do
    update <- lookupEnv "UPDATE_GOLDENS"
    exists <- doesFileExist path
    unless (exists && update /= Just "1") $
        writeIntentFile path some
    onDisk <- BSL.readFile path
    onDisk
        `shouldBe` encodeSomeTreasuryIntent some

intentDrivenCbor
    :: FilePath -> ChainContext -> IO BSL.ByteString
intentDrivenCbor path ctx = do
    parsed <- decodeTreasuryIntentFile path
    some <- case parsed of
        Left e ->
            error ("intent JSON parse failed: " <> e)
        Right ok -> pure ok
    brCborBytes <$> runFromIntent ctx some

expectAdjustedMaterializationCoreCbor
    :: String
    -> GovernanceWithdrawalInitMaterializationTx
    -> ChainContext
    -> [(TxIn, TxOut ConwayEra)]
    -> Either e ConwayTx
    -> IO BSL.ByteString
expectAdjustedMaterializationCoreCbor label tx ctx refUtxos = \case
    Left _ ->
        expectationFailure
            (label <> ": construction core returned Left")
            >> pure BSL.empty
    Right coreTx -> do
        txWithWithdrawal <-
            case addWithdrawalToChange 1 (gwimtRewardsAmount tx) coreTx of
                Left e ->
                    expectationFailure
                        (label <> ": addWithdrawalToChange failed: " <> e)
                        >> pure coreTx
                Right ok -> pure ok
        adjustedTx <-
            case alignCardanoCliBuildFee
                (ccPParams ctx)
                refUtxos
                1
                txWithWithdrawal of
                Left e ->
                    expectationFailure
                        (label <> ": fee alignment failed: " <> e)
                        >> pure txWithWithdrawal
                Right ok -> pure ok
        pure
            ( serialize
                (eraProtVerLow @ConwayEra)
                (adjustedTx :: ConwayTx)
            )

frozenEvaluator
    :: ChainContext
    -> ( ConwayTx
         -> IO
                ( Map.Map
                    (ConwayPlutusPurpose AsIx ConwayEra)
                    (Either String ExUnits)
                )
       )
frozenEvaluator ctx tx = do
    m <- ccEvaluateTx ctx tx
    pure (Map.map (either (Left . show) Right) m)
