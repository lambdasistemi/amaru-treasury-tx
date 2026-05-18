{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardSeedSplitSpec
Description : CBOR-parity golden for registry-init-wizard seed-split
License     : Apache-2.0

Slice 2 of #158. The wizard produces a 'SomeTreasuryIntent'
from typed 'RegistryInitSeedSplitAnswers' + 'RegistryInitEnv';
that intent — round-tripped through the @tx-build@
dispatcher ('Amaru.Treasury.Build.runFromIntent') — must
produce CBOR byte-identical to what @buildSeedSplitCore@
emits from the same underlying fixture.

The fixture helpers in 'Support.RegistryInitWizardFixtures'
and 'Support.RegistryInitFixtures' anchor both halves to the
same 'RegistryInitFixture' record so the parity proof cannot
drift.

Set @UPDATE_GOLDENS=1@ to rewrite the canonical fixtures
under @test/fixtures/registry-init-wizard/@.
-}
module Amaru.Treasury.Tx.RegistryInitWizardSeedSplitSpec (spec) where

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
    ( buildSeedSplitCore
    )
import Amaru.Treasury.IntentJSON
    ( RegistryInitSeedSplitTx (..)
    , SomeTreasuryIntent (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Tx.RegistryInitWizard
    ( registryInitSeedSplitToIntent
    )

import Support.RegistryInitFixtures
    ( RegistryInitFixture (..)
    , seedSplitFixture
    , writeIntentFile
    )
import Support.RegistryInitWizardFixtures
    ( seedSplitIntentFixturePath
    , seedSplitWizardFixture
    )

spec :: Spec
spec =
    describe "registry-init-wizard seed-split CBOR parity" $
        it
            "wizard intent CBOR equals buildSeedSplitCore CBOR"
            seedSplitParity

seedSplitParity :: IO ()
seedSplitParity = do
    fixture <- seedSplitFixture
    let (answers, env) = seedSplitWizardFixture fixture
    intent <- case registryInitSeedSplitToIntent env answers of
        Left e ->
            error
                ( "registryInitSeedSplitToIntent failed: "
                    <> show e
                )
        Right i -> pure i
    -- Wizard intent must match the library-core fixture
    -- intent that 'Support.RegistryInitFixtures' carries.
    intent `shouldBe` rifIntent fixture
    materializeOrLoadIntent seedSplitIntentFixturePath intent
    intentCbor <-
        intentDrivenCbor
            seedSplitIntentFixturePath
            (rifContext fixture)
    let tx = rifTranslated fixture
        ctx = rifContext fixture
    seed <- case rifInputUtxos fixture of
        [u] -> pure u
        other ->
            error
                ( "seed-split fixture must carry exactly one \
                  \input UTxO, got: "
                    <> show (length other)
                )
    coreResult <-
        buildSeedSplitCore
            (ccPParams ctx)
            (risstFundingAddress tx)
            (risstUpperBoundSlot tx)
            seed
            (frozenEvaluator ctx)
    coreCbor <- expectCoreCbor "seed-split" coreResult
    intentCbor `shouldBe` coreCbor

-- ----------------------------------------------------
-- Shared plumbing (lifted from RegistryInitIntentSpec)
-- ----------------------------------------------------

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
