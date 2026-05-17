{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : StakeRewardInitIntentSpec
Description : CBOR-equivalence goldens for stake-reward-init dispatch
License     : Apache-2.0

For each of the two flat @stake-reward-init-*@ sub-actions
the test compares the CBOR bytes produced by:

* the @tx-build@ dispatcher running on the parsed intent
  ('Amaru.Treasury.Build.runFromIntent'); and
* the construction core in
  "Amaru.Treasury.Devnet.StakeRewardInit" called directly
  with the same logical inputs.

Both halves originate from a single
'StakeRewardInitFixture' record built by
'Support.StakeRewardInitFixtures', so the fixture intent
JSON and the direct-core call cannot drift.

Set @UPDATE_GOLDENS=1@ to (re)write the canonical
@test/fixtures/intent/stake-reward-init-*.json@ files from
the in-memory intents emitted by the fixture helper.
-}
module StakeRewardInitIntentSpec (spec) where

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
import Amaru.Treasury.Devnet.StakeRewardInit
    ( buildStakeRewardPlainAccountCore
    , buildStakeRewardScriptAccountCore
    )
import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , StakeRewardInitPlainAccountTx (..)
    , StakeRewardInitScriptAccountTx (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )

import Support.StakeRewardInitFixtures
    ( StakeRewardInitFixture (..)
    , plainAccountFixture
    , plainAccountIntentPath
    , scriptAccountFixture
    , scriptAccountIntentPath
    , writeIntentFile
    )

spec :: Spec
spec =
    describe "stake-reward-init dispatch CBOR equivalence" $ do
        it
            "stake-reward-init-script-account builds CBOR \
            \identical to registerScriptRewardAccount's core"
            scriptAccountEquivalence
        it
            "stake-reward-init-plain-account builds CBOR \
            \identical to registerPlainRewardAccount's core"
            plainAccountEquivalence

-- ----------------------------------------------------
-- Per-sub-action assertions
-- ----------------------------------------------------

scriptAccountEquivalence :: IO ()
scriptAccountEquivalence = do
    fixture <- scriptAccountFixture
    materializeOrLoadIntent
        scriptAccountIntentPath
        (srifIntent fixture)
    intentCbor <-
        intentDrivenCbor
            scriptAccountIntentPath
            (srifContext fixture)
    let tx = srifTranslated fixture
        ctx = srifContext fixture
        [seed, treasuryRefUtxo] = srifInputUtxos fixture
    coreResult <-
        buildStakeRewardScriptAccountCore
            (ccPParams ctx)
            (srisatFundingAddress tx)
            (srisatTreasuryCredential tx)
            (srisatTreasuryRefTxIn tx)
            (srisatUpperBoundSlot tx)
            seed
            treasuryRefUtxo
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor "stake-reward-script-account" coreResult
    intentCbor `shouldBe` coreCbor

plainAccountEquivalence :: IO ()
plainAccountEquivalence = do
    fixture <- plainAccountFixture
    materializeOrLoadIntent
        plainAccountIntentPath
        (srifIntent fixture)
    intentCbor <-
        intentDrivenCbor
            plainAccountIntentPath
            (srifContext fixture)
    let tx = srifTranslated fixture
        ctx = srifContext fixture
        [seed] = srifInputUtxos fixture
    coreResult <-
        buildStakeRewardPlainAccountCore
            (ccPParams ctx)
            (srispatFundingAddress tx)
            (srispatPermissionsCredential tx)
            (srispatUpperBoundSlot tx)
            seed
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor "stake-reward-plain-account" coreResult
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
