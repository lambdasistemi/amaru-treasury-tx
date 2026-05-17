{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : GovernanceWithdrawalInitIntentSpec
Description : CBOR-equivalence goldens for governance-withdrawal-init dispatch
License     : Apache-2.0

For each of the two flat @governance-withdrawal-init-*@
sub-actions the test compares the CBOR bytes produced by:

* the @tx-build@ dispatcher running on the parsed intent
  ('Amaru.Treasury.Build.runFromIntent'); and
* the construction core in
  "Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core"
  called directly with the same logical inputs.

Both halves originate from a single
'GovernanceWithdrawalInitFixture' record built by
'Support.GovernanceWithdrawalInitFixtures', so the fixture
intent JSON and the direct-core call cannot drift.

Set @UPDATE_GOLDENS=1@ to (re)write the canonical
@test/fixtures/intent/governance-withdrawal-init-*.json@
files from the in-memory intents emitted by the fixture
helper.
-}
module GovernanceWithdrawalInitIntentSpec (spec) where

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
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( buildGovernanceWithdrawalMaterializationCore
    , buildGovernanceWithdrawalProposalCore
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitMaterializationTx (..)
    , GovernanceWithdrawalInitProposalTx (..)
    , SomeTreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )

import Support.GovernanceWithdrawalInitFixtures
    ( GovernanceWithdrawalInitFixture (..)
    , materializationFixture
    , materializationIntentPath
    , proposalFixture
    , proposalIntentPath
    , writeIntentFile
    )

spec :: Spec
spec =
    describe "governance-withdrawal-init dispatch CBOR equivalence" $ do
        it
            "governance-withdrawal-init-proposal builds CBOR \
            \identical to submitGovernanceWithdrawal's core"
            proposalEquivalence
        it
            "governance-withdrawal-init-materialization builds \
            \CBOR identical to buildWithdrawalTransaction's core"
            materializationEquivalence

-- ----------------------------------------------------
-- Per-sub-action assertions
-- ----------------------------------------------------

proposalEquivalence :: IO ()
proposalEquivalence = do
    fixture <- proposalFixture
    materializeOrLoadIntent
        proposalIntentPath
        (gwifIntent fixture)
    intentCbor <-
        intentDrivenCbor
            proposalIntentPath
            (gwifContext fixture)
    let tx = gwifTranslated fixture
        ctx = gwifContext fixture
        [seed] = gwifInputUtxos fixture
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
            seed
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor
            "governance-withdrawal-proposal"
            coreResult
    intentCbor `shouldBe` coreCbor

materializationEquivalence :: IO ()
materializationEquivalence = do
    fixture <- materializationFixture
    materializeOrLoadIntent
        materializationIntentPath
        (gwifIntent fixture)
    intentCbor <-
        intentDrivenCbor
            materializationIntentPath
            (gwifContext fixture)
    let tx = gwifTranslated fixture
        ctx = gwifContext fixture
        [seed, treasuryRefUtxo, registryRefUtxo] =
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
            seed
            treasuryRefUtxo
            registryRefUtxo
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor
            "governance-withdrawal-materialization"
            coreResult
    intentCbor `shouldBe` coreCbor

-- ----------------------------------------------------
-- Shared plumbing
-- ----------------------------------------------------

{- | Ensure the fixture intent.json exists; create it under
@UPDATE_GOLDENS=1@ or when the file is missing so a fresh
checkout regenerates the canonical payload deterministically.
A pre-existing file is rewritten to match the in-memory
intent on update so the goldens stay self-consistent.
-}
materializeOrLoadIntent
    :: FilePath -> SomeTreasuryIntent -> IO ()
materializeOrLoadIntent path some = do
    update <- lookupEnv "UPDATE_GOLDENS"
    exists <- doesFileExist path
    unless (exists && update /= Just "1") $
        writeIntentFile path some
    -- Sanity-check: the on-disk file equals the in-memory
    -- intent's pretty-printed encoding.
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

{- | Lift a 'ChainContext' \'s evaluator into the
'Cardano.Tx.Build.build'-friendly shape used by the
construction cores.
-}
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
