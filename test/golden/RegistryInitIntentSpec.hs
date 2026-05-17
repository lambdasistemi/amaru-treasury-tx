{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : RegistryInitIntentSpec
Description : CBOR-equivalence goldens for registry-init dispatch
License     : Apache-2.0

For each of the three flat @registry-init-*@ sub-actions the
test compares the CBOR bytes produced by:

* the @tx-build@ dispatcher running on the parsed intent
  ('Amaru.Treasury.Build.runFromIntent'); and
* the construction core in
  "Amaru.Treasury.Devnet.RegistryInit" called directly with
  the same logical inputs.

Both halves originate from a single 'RegistryInitFixture'
record built by 'Support.RegistryInitFixtures', so the
fixture intent JSON and the direct-core call cannot drift.

Set @UPDATE_GOLDENS=1@ to (re)write the canonical
@test/fixtures/intent/registry-init-*.json@ files from the
in-memory intents emitted by the fixture helper.
-}
module RegistryInitIntentSpec (spec) where

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
import Amaru.Treasury.Devnet.RegistryInit
    ( buildReferenceScriptsCore
    , buildRegistryNftsCore
    , buildSeedSplitCore
    , deriveDevnetScripts
    )
import Amaru.Treasury.IntentJSON
    ( RegistryInitMintTx (..)
    , RegistryInitReferenceScriptsTx (..)
    , RegistryInitSeedSplitTx (..)
    , SomeTreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )

import Support.RegistryInitFixtures
    ( RegistryInitFixture (..)
    , mintFixture
    , mintIntentPath
    , referenceScriptsFixture
    , referenceScriptsIntentPath
    , seedSplitFixture
    , seedSplitIntentPath
    , writeIntentFile
    )

spec :: Spec
spec =
    describe "registry-init dispatch CBOR equivalence" $ do
        it
            "registry-init-seed-split builds CBOR identical \
            \to submitSeedSplit's core"
            seedSplitEquivalence
        it
            "registry-init-mint builds CBOR identical to \
            \submitRegistryNfts's core"
            mintEquivalence
        it
            "registry-init-reference-scripts builds CBOR \
            \identical to submitReferenceScripts's core"
            referenceScriptsEquivalence

-- ----------------------------------------------------
-- Per-sub-action assertions
-- ----------------------------------------------------

seedSplitEquivalence :: IO ()
seedSplitEquivalence = do
    fixture <- seedSplitFixture
    materializeOrLoadIntent
        seedSplitIntentPath
        (rifIntent fixture)
    intentCbor <-
        intentDrivenCbor seedSplitIntentPath (rifContext fixture)
    let tx = rifTranslated fixture
        ctx = rifContext fixture
        [seed] = rifInputUtxos fixture
    coreResult <-
        buildSeedSplitCore
            (ccPParams ctx)
            (risstFundingAddress tx)
            (risstUpperBoundSlot tx)
            seed
            (frozenEvaluator ctx)
    coreCbor <- expectCoreCbor "seed-split" coreResult
    intentCbor `shouldBe` coreCbor

mintEquivalence :: IO ()
mintEquivalence = do
    fixture <- mintFixture
    materializeOrLoadIntent
        mintIntentPath
        (rifIntent fixture)
    intentCbor <-
        intentDrivenCbor mintIntentPath (rifContext fixture)
    let tx = rifTranslated fixture
        ctx = rifContext fixture
        seedOuts = rifInputUtxos fixture
    scripts <-
        deriveDevnetScripts
            (rimtNetwork tx)
            (rimtScopesSeedTxIn tx)
            (rimtRegistrySeedTxIn tx)
    coreResult <-
        buildRegistryNftsCore
            (ccPParams ctx)
            (rimtFundingAddress tx)
            (rimtNetwork tx)
            (rimtOwnerKeyHash tx)
            scripts
            (rimtUpperBoundSlot tx)
            seedOuts
            (frozenEvaluator ctx)
    coreCbor <- expectCoreCbor "mint" coreResult
    intentCbor `shouldBe` coreCbor

referenceScriptsEquivalence :: IO ()
referenceScriptsEquivalence = do
    fixture <- referenceScriptsFixture
    materializeOrLoadIntent
        referenceScriptsIntentPath
        (rifIntent fixture)
    intentCbor <-
        intentDrivenCbor
            referenceScriptsIntentPath
            (rifContext fixture)
    let tx = rifTranslated fixture
        ctx = rifContext fixture
        [seed] = rifInputUtxos fixture
    scripts <-
        deriveDevnetScripts
            (rirstNetwork tx)
            (rirstScopesSeedTxIn tx)
            (rirstRegistrySeedTxIn tx)
    coreResult <-
        buildReferenceScriptsCore
            (ccPParams ctx)
            (rirstFundingAddress tx)
            scripts
            (rirstUpperBoundSlot tx)
            seed
            (frozenEvaluator ctx)
    coreCbor <- expectCoreCbor "reference-scripts" coreResult
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
