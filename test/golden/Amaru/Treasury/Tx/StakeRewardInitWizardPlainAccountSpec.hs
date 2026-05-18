{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.StakeRewardInitWizardPlainAccountSpec
Description : CBOR-parity golden for stake-reward-init-wizard plain-account
License     : Apache-2.0

Slice 3 of #159. The wizard produces a 'SomeTreasuryIntent'
from typed 'StakeRewardInitPlainAccountAnswers' +
'StakeRewardInitEnv'; that intent — round-tripped through
the @tx-build@ dispatcher
('Amaru.Treasury.Build.runFromIntent') — must produce CBOR
byte-identical to what @buildStakeRewardPlainAccountCore@
emits from the same underlying fixture.

Three assertions:

* @intent shouldBe srifIntent fixture@ — the wizard pure
  translation produces the same in-memory intent the
  library-core fixture carries.
* the on-disk @registry.json@ test fixture parses cleanly
  via 'readDevnetStakeRewardRegistry' and equals the
  projection the helper derives from the fixture material —
  same assertion as the script-account spec, because the two
  sub-actions share one registry on disk (NFR-007).
* the wizard's intent → dispatcher CBOR equals the core's
  CBOR (modelled on
  'Amaru.Treasury.Tx.StakeRewardInitWizardScriptAccountSpec').

Set @UPDATE_GOLDENS=1@ to rewrite the canonical fixtures
under @test/fixtures/stake-reward-init-wizard/@.
-}
module Amaru.Treasury.Tx.StakeRewardInitWizardPlainAccountSpec
    ( spec
    ) where

import Control.Monad (unless)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
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
    ( DevnetStakeRewardRegistry (..)
    , buildStakeRewardPlainAccountCore
    , readDevnetStakeRewardRegistry
    )
import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , StakeRewardInitPlainAccountTx (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( stakeRewardInitPlainAccountToIntent
    )

import Support.StakeRewardInitFixtures
    ( StakeRewardInitFixture (..)
    , plainAccountFixture
    , scriptAccountFixture
    , writeIntentFile
    )
import Support.StakeRewardInitWizardFixtures
    ( parsedRegistryFromPlainAccountFixture
    , plainAccountIntentFixturePath
    , plainAccountWizardFixture
    , registryFixturePath
    )

spec :: Spec
spec =
    describe "stake-reward-init-wizard plain-account CBOR parity" $ do
        it
            "wizard intent CBOR equals \
            \buildStakeRewardPlainAccountCore CBOR"
            plainAccountParity
        it
            "fixture registry.json parses via \
            \readDevnetStakeRewardRegistry (plain-account view)"
            registryFixtureParses

plainAccountParity :: IO ()
plainAccountParity = do
    sa <- scriptAccountFixture
    pa <- plainAccountFixture
    let (answers, env) = plainAccountWizardFixture sa pa
    intent <-
        case stakeRewardInitPlainAccountToIntent env answers of
            Left e ->
                error
                    ( "stakeRewardInitPlainAccountToIntent \
                      \failed: "
                        <> show e
                    )
            Right i -> pure i
    -- Wizard intent must match the library-core fixture
    -- intent that 'Support.StakeRewardInitFixtures' carries.
    intent `shouldBe` srifIntent pa
    materializeOrLoadIntent plainAccountIntentFixturePath intent
    intentCbor <-
        intentDrivenCbor
            plainAccountIntentFixturePath
            (srifContext pa)
    let tx = srifTranslated pa
        ctx = srifContext pa
        [seed] = srifInputUtxos pa
    coreResult <-
        buildStakeRewardPlainAccountCore
            (ccPParams ctx)
            (srispatFundingAddress tx)
            (srispatPermissionsCredential tx)
            (srispatUpperBoundSlot tx)
            seed
            (frozenEvaluator ctx)
    coreCbor <-
        expectCoreCbor "stake-reward-init-plain-account" coreResult
    intentCbor `shouldBe` coreCbor

{- | Verifies the shared @registry.json@ test fixture parses
cleanly through the production
'readDevnetStakeRewardRegistry' AND equals the projection
'Support.StakeRewardInitWizardFixtures' derives from the
script-account fixture (the registry file is
sub-action-independent; the plain-account projection equals
the script-account one).

The on-disk JSON is materialized on first run or when
@UPDATE_GOLDENS=1@; a drift in the script-set seeds or in
'deriveDevnetScripts' would break this assertion via the
hardcoded 'fixturePermissionsScriptHash' carried by the
projection.
-}
registryFixtureParses :: IO ()
registryFixtureParses = do
    sa <- scriptAccountFixture
    let expected = parsedRegistryFromPlainAccountFixture sa
    materializeRegistryIfMissing registryFixturePath expected
    parsedE <- readDevnetStakeRewardRegistry registryFixturePath
    case parsedE of
        Left e ->
            expectationFailure
                ("registry.json failed to parse: " <> e)
        Right parsed ->
            parsed `shouldBe` expected

materializeRegistryIfMissing
    :: FilePath -> DevnetStakeRewardRegistry -> IO ()
materializeRegistryIfMissing path expected = do
    update <- lookupEnv "UPDATE_GOLDENS"
    exists <- doesFileExist path
    unless (exists && update /= Just "1") $
        BSL.writeFile path (renderRegistryFixture expected)

renderRegistryFixture
    :: DevnetStakeRewardRegistry -> BSL.ByteString
renderRegistryFixture r =
    BSL.fromStrict
        ( TE.encodeUtf8
            ( T.unlines
                [ "{"
                , "  \"phase\": \"registry-init\","
                , "  \"network\": \"devnet\","
                , "  \"anchors\": {"
                , "    \"permissionsDeployedAt\": \""
                    <> txInTextG (dsrrPermissionsRef r)
                    <> "\","
                , "    \"treasuryDeployedAt\": \""
                    <> txInTextG (dsrrTreasuryRef r)
                    <> "\""
                , "  },"
                , "  \"scripts\": {"
                , "    \"permissionsScriptHash\": \""
                    <> scriptHashToHex
                        (dsrrPermissionsScriptHash r)
                    <> "\","
                , "    \"treasuryScriptHash\": \""
                    <> scriptHashToHex
                        (dsrrTreasuryScriptHash r)
                    <> "\""
                , "  }"
                , "}"
                ]
            )
        )

txInTextG :: TxIn -> T.Text
txInTextG (TxIn (TxId h) ix) =
    TE.decodeUtf8Lenient
        (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))

-- ----------------------------------------------------
-- Shared plumbing
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
