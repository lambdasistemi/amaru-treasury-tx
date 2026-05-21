{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardProposalSpec
Description : CBOR-parity golden for governance-withdrawal-init-wizard proposal
License     : Apache-2.0

Slice 2 of #160. The wizard produces a 'SomeTreasuryIntent'
from typed 'GovernanceWithdrawalInitProposalAnswers' +
'GovernanceWithdrawalInitEnv'; that intent — round-tripped
through the @tx-build@ dispatcher
('Amaru.Treasury.Build.runFromIntent') — must produce CBOR
byte-identical to what 'buildGovernanceWithdrawalProposalCore'
emits from the same underlying fixture.

Four checks:

* @intent shouldBe gwifIntent fixture@ — the wizard pure
  translation produces the same in-memory intent the
  library-core fixture carries.
* the on-disk @registry.json@ + @accounts.json@ test
  fixtures parse cleanly via
  'readDevnetGovernanceWithdrawalRegistry' /
  'readDevnetGovernanceStakeRewardAccounts' and equal the
  projections the helper derives from the fixture material
  — so the JSON files cannot drift from the typed Env.
* the wizard's intent → dispatcher CBOR equals the core's
  CBOR (modelled on
  'Amaru.Treasury.Tx.StakeRewardInitWizardScriptAccountSpec').
* an invalid upper-bound slot is rejected through the final Phase-1
  path, proving the proposal builder no longer skips structural
  ledger validation.

Set @UPDATE_GOLDENS=1@ to rewrite the canonical fixtures
under @test/fixtures/governance-withdrawal-init-wizard/@.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardProposalSpec
    ( spec
    ) where

import Control.Monad (unless)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
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
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    , runFromIntentEither
    )
import Amaru.Treasury.Build.Error
    ( BuildDiagnostic (..)
    , BuildError (..)
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccounts
    , DevnetGovernanceWithdrawalRegistry
    , readDevnetGovernanceStakeRewardAccounts
    , readDevnetGovernanceWithdrawalRegistry
    )
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( buildGovernanceWithdrawalProposalCore
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitProposalTx (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( governanceWithdrawalInitProposalToIntent
    )

import Support.GovernanceWithdrawalInitFixtures
    ( GovernanceWithdrawalInitFixture (..)
    , proposalFixture
    , writeIntentFile
    )
import Support.GovernanceWithdrawalInitWizardFixtures
    ( accountsFixturePath
    , parsedAccountsFromProposalFixture
    , parsedRegistryFromProposalFixture
    , proposalIntentFixturePath
    , proposalWizardFixture
    , registryFixturePath
    , renderAccountsFixture
    , renderRegistryFixture
    )

spec :: Spec
spec =
    describe "governance-withdrawal-init-wizard proposal CBOR parity" $ do
        it
            "wizard intent CBOR equals \
            \buildGovernanceWithdrawalProposalCore CBOR"
            proposalParity
        it
            "fixture registry.json parses via \
            \readDevnetGovernanceWithdrawalRegistry"
            registryFixtureParses
        it
            "fixture accounts.json parses via \
            \readDevnetGovernanceStakeRewardAccounts"
            accountsFixtureParses
        it
            "proposal build rejects an invalid upper slot through Phase-1 validation"
            proposalRejectsInvalidUpperSlot

proposalParity :: IO ()
proposalParity = do
    fixture <- proposalFixture
    let (answers, env) = proposalWizardFixture fixture
    intent <-
        case governanceWithdrawalInitProposalToIntent env answers of
            Left e ->
                error
                    ( "governanceWithdrawalInitProposalToIntent \
                      \failed: "
                        <> show e
                    )
            Right i -> pure i
    -- Wizard intent must match the library-core fixture
    -- intent that 'Support.GovernanceWithdrawalInitFixtures'
    -- carries.
    intent `shouldBe` gwifIntent fixture
    materializeOrLoadIntent proposalIntentFixturePath intent
    intentCbor <-
        intentDrivenCbor
            proposalIntentFixturePath
            (gwifContext fixture)
    let tx = gwifTranslated fixture
        ctx = gwifContext fixture
    seedUtxo <-
        case gwifInputUtxos fixture of
            [seed] -> pure seed
            inputs ->
                expectationFailure
                    ( "expected one proposal input UTxO, got "
                        <> show (length inputs)
                    )
                    >> error "unreachable"
    coreResult <-
        buildGovernanceWithdrawalProposalCore
            (ccPParams ctx)
            (gwiptFundingAddress tx)
            (gwiptFundingCredential tx)
            (gwiptVoterCredential tx)
            (gwiptDrepCredential tx)
            (gwiptDrepKey tx)
            (gwiptVoterBaseAddr tx)
            (gwiptReturnAccount tx)
            (gwiptTreasuryAccount tx)
            (gwiptAmount tx)
            (gwiptUpperBoundSlot tx)
            (gwiptAnchor tx)
            seedUtxo
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor "governance-withdrawal-init-proposal" coreResult
    intentCbor `shouldBe` coreCbor

registryFixtureParses :: IO ()
registryFixtureParses = do
    fixture <- proposalFixture
    let expected = parsedRegistryFromProposalFixture fixture
    materializeRegistryIfMissing registryFixturePath expected
    parsedE <- readDevnetGovernanceWithdrawalRegistry registryFixturePath
    case parsedE of
        Left e ->
            expectationFailure
                ("registry.json failed to parse: " <> e)
        Right parsed ->
            parsed `shouldBe` expected

accountsFixtureParses :: IO ()
accountsFixtureParses = do
    fixture <- proposalFixture
    let expected = parsedAccountsFromProposalFixture fixture
    materializeAccountsIfMissing accountsFixturePath expected
    parsedE <- readDevnetGovernanceStakeRewardAccounts accountsFixturePath
    case parsedE of
        Left e ->
            expectationFailure
                ("accounts.json failed to parse: " <> e)
        Right parsed ->
            parsed `shouldBe` expected

proposalRejectsInvalidUpperSlot :: IO ()
proposalRejectsInvalidUpperSlot = do
    fixture <- proposalFixture
    invalidSome <-
        case gwifIntent fixture of
            SomeTreasuryIntent SGovernanceWithdrawalInitProposal intent ->
                pure $
                    SomeTreasuryIntent
                        SGovernanceWithdrawalInitProposal
                        intent{tiValidityUpperBoundSlot = 999_999}
            _ -> do
                expectationFailure "expected proposal intent fixture"
                error "unreachable"
    result <-
        runFromIntentEither
            (gwifContext fixture)
            invalidSome
    case result of
        Left err ->
            assertOutsideValidityInterval err
        Right{} ->
            expectationFailure
                "expected OutsideValidityIntervalUTxO, \
                \but proposal build skipped Phase-1 validation"

assertOutsideValidityInterval :: BuildError -> IO ()
assertOutsideValidityInterval err =
    case beDiagnostic err of
        DiagnosticChecksFailed msg
            | "OutsideValidityIntervalUTxO" `T.isInfixOf` msg ->
                pure ()
        other ->
            expectationFailure $
                "expected OutsideValidityIntervalUTxO, got "
                    <> show other

materializeRegistryIfMissing
    :: FilePath -> DevnetGovernanceWithdrawalRegistry -> IO ()
materializeRegistryIfMissing path expected = do
    update <- lookupEnv "UPDATE_GOLDENS"
    exists <- doesFileExist path
    unless (exists && update /= Just "1") $
        BSL.writeFile path (renderRegistryFixture expected)

materializeAccountsIfMissing
    :: FilePath -> DevnetGovernanceStakeRewardAccounts -> IO ()
materializeAccountsIfMissing path expected = do
    update <- lookupEnv "UPDATE_GOLDENS"
    exists <- doesFileExist path
    unless (exists && update /= Just "1") $
        BSL.writeFile path (renderAccountsFixture expected)

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

expectCoreCbor
    :: String
    -> Either e ConwayTx
    -> IO BSL.ByteString
expectCoreCbor label = \case
    Left _ ->
        expectationFailure
            (label <> ": construction core returned Left")
            >> pure BSL.empty
    Right tx ->
        pure
            ( serialize
                (eraProtVerLow @ConwayEra)
                (tx :: ConwayTx)
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
