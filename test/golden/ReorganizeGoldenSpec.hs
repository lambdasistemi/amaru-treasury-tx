{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : ReorganizeGoldenSpec
Description : Offline golden harness for reorganize materialization
License     : Apache-2.0

Loads the synthetic frozen reorganize fixture under
@test/fixtures/reorganize-core/synthetic/@, decodes the unified
@intent.json@, and builds a transaction via 'runFromIntent'
against the resulting frozen 'ChainContext'.

Set @UPDATE_GOLDENS=1@ to regenerate @expected.cbor@ from the
checked-in fixture. Without that flag, missing or changed bytes
are reported by the test.
-}
module ReorganizeGoldenSpec (spec) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Addr, Withdrawals (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose (..)
    )
import Cardano.Ledger.Core (TopTx, TxBody)
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.Metadata (Metadatum)
import Lens.Micro ((^.))

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , rationaleMetadatum
    )
import Amaru.Treasury.Build
    ( BuildResult (..)
    , ScriptResult (..)
    , runFromIntent
    )
import Amaru.Treasury.Build.Error
    ( ActionBuildError (..)
    , BuildDiagnostic (..)
    )
import Amaru.Treasury.Build.Reorganize
    ( runReorganizeAction
    )
import Amaru.Treasury.ChainContext
    ( ChainContext (..)
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , RationaleJSON (..)
    , ReorganizeInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , parseAddr
    )
import Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/reorganize-core/synthetic"

overflowDir :: FilePath
overflowDir = "test/fixtures/reorganize-core/synthetic-overflow"

data ReorganizeCase = ReorganizeCase
    { rcContext :: !ChainContext
    , rcIntent :: !ReorganizeIntent
    , rcSomeIntent :: !SomeTreasuryIntent
    , rcRationale :: !Metadatum
    , rcWalletAddress :: !Addr
    }

spec :: Spec
spec =
    describe "reorganize golden (synthetic frozen ChainContext)" $ do
        it "rebuilds expected.cbor byte-for-byte" $ do
            ReorganizeCase{..} <- loadReorganizeCase fixtureDir
            let expectedPath = fixtureDir <> "/expected.cbor"
            expectedExists <- doesFileExist expectedPath
            update <- lookupEnv "UPDATE_GOLDENS"
            unless (expectedExists || update == Just "1") $
                expectationFailure
                    "missing expected.cbor; run UPDATE_GOLDENS=1 just golden reorganize"
            result <-
                runFromIntent
                    rcContext
                    rcSomeIntent
            assertReorganizeShape rcContext rcIntent result
            let actualHex =
                    B16.encode
                        (BSL.toStrict (brCborBytes result))
            if update == Just "1"
                then BS.writeFile expectedPath actualHex
                else do
                    expected <- BS.readFile expectedPath
                    actualHex `shouldBe` expected

        it "reports missing required UTxOs before building" $ do
            ReorganizeCase{..} <- loadReorganizeCase fixtureDir
            let missingTreasury =
                    NE.head (rgiTreasuryUtxos rcIntent)
                ctxMissing =
                    rcContext
                        { ccUtxos =
                            Map.delete
                                missingTreasury
                                (ccUtxos rcContext)
                        }
            result <-
                runExceptT $
                    runReorganizeAction
                        ctxMissing
                        rcIntent
                        rcRationale
                        rcWalletAddress
            case result of
                Left ActionBuildError{abeDiagnostic = got} ->
                    got `shouldSatisfy` \case
                        DiagnosticMissingUtxos missing ->
                            not (null missing)
                        _ -> False
                Right{} ->
                    expectationFailure
                        "expected missing UTxO diagnostic"

        it "surfaces exec-units overflow as phase-1 checks failed" $ do
            ReorganizeCase{..} <- loadReorganizeCase overflowDir
            result <-
                runExceptT $
                    runReorganizeAction
                        rcContext
                        rcIntent
                        rcRationale
                        rcWalletAddress
            case result of
                Left ActionBuildError{abeDiagnostic = got} ->
                    got `shouldSatisfy` \case
                        DiagnosticChecksFailed msg ->
                            not (T.null msg)
                        _ -> False
                Right{} ->
                    expectationFailure
                        "expected DiagnosticChecksFailed for overflow fixture"

loadReorganizeCase :: FilePath -> IO ReorganizeCase
loadReorganizeCase dir = do
    some <-
        expectRightIO
            =<< decodeTreasuryIntentFile
                (dir <> "/intent.json")
    fixture <- readSwapFixture dir
    case some of
        SomeTreasuryIntent SReorganize ti -> do
            walletAddress <-
                expectRightIO $
                    parseAddr (wjAddress (tiWallet ti))
            rationale <- expectRightIO (rationaleFor ti)
            pure
                ReorganizeCase
                    { rcContext = toFrozenContext fixture
                    , rcIntent =
                        reorganizeIntentFromInputs
                            (tiPayload ti)
                    , rcSomeIntent = some
                    , rcRationale = rationale
                    , rcWalletAddress = walletAddress
                    }
        _ ->
            expectationFailure "expected reorganize intent fixture"
                >> error "unreachable"

reorganizeIntentFromInputs :: ReorganizeInputs -> ReorganizeIntent
reorganizeIntentFromInputs ReorganizeInputs{..} =
    ReorganizeIntent
        { rgiWalletUtxo = riWalletUtxo
        , rgiTreasuryUtxos = riTreasuryUtxos
        , rgiTreasuryAddress = riTreasuryAddress
        , rgiTreasuryDeployedAt = riTreasuryDeployedAt
        , rgiRegistryDeployedAt = riRegistryDeployedAt
        , rgiPermissionsRewardAccount = riPermissionsRewardAccount
        , rgiPermissionsDeployedAt = riPermissionsDeployedAt
        , rgiScopeOwnerSigner = riScopeOwnerSigner
        , rgiUpperBound = riUpperBound
        }

rationaleFor
    :: TreasuryIntent 'Reorganize -> Either String Metadatum
rationaleFor ti = do
    registryPolicy <-
        decodeHexBytes 28 (sjRegistryPolicyId (tiScope ti))
    let RationaleJSON{..} = tiRationale ti
        body =
            RationaleBody
                { rbEvent = rjEvent
                , rbLabel = rjLabel
                , rbDescription = [rjDescription]
                , rbDestinationLabel = rjDestinationLabel
                , rbJustification = [rjJustification]
                }
    pure (rationaleMetadatum body registryPolicy)

assertReorganizeShape
    :: ChainContext -> ReorganizeIntent -> BuildResult -> IO ()
assertReorganizeShape ctx intent result = do
    let body = brFinalTxBody result
        expectedInputs =
            Set.fromList
                ( rgiWalletUtxo intent
                    : NE.toList (rgiTreasuryUtxos intent)
                )
        expectedRefs =
            Set.fromList
                [ rgiTreasuryDeployedAt intent
                , rgiRegistryDeployedAt intent
                , rgiPermissionsDeployedAt intent
                ]
    expectedInputs
        `shouldSatisfy` (`Set.isSubsetOf` (body ^. inputsTxBodyL))
    body ^. referenceInputsTxBodyL `shouldBe` expectedRefs
    assertContinuingOutput ctx intent body
    let Withdrawals withdrawals = body ^. withdrawalsTxBodyL
    withdrawals
        `shouldBe` Map.singleton
            (rgiPermissionsRewardAccount intent)
            (Coin 0)
    body
        ^. reqSignerHashesTxBodyL
        `shouldBe` Set.singleton (rgiScopeOwnerSigner intent)
    body ^. vldtTxBodyL `shouldSatisfy` \(ValidityInterval _ to) ->
        to == SJust (rgiUpperBound intent)
    srPurpose <$> brScriptResults result
        `shouldBe` [ ConwaySpending (AsIx 0)
                   , ConwaySpending (AsIx 1)
                   , ConwayRewarding (AsIx 0)
                   ]

assertContinuingOutput
    :: ChainContext
    -> ReorganizeIntent
    -> TxBody TopTx ConwayEra
    -> IO ()
assertContinuingOutput ctx intent body = do
    let outs = toList (body ^. outputsTxBodyL)
        preserved = preservedValue ctx intent
    length outs `shouldBe` 2
    case outs of
        continuing : _ -> do
            continuing ^. addrTxOutL
                `shouldBe` rgiTreasuryAddress intent
            continuing ^. valueTxOutL `shouldBe` preserved
        [] -> expectationFailure "expected continuing output"

preservedValue :: ChainContext -> ReorganizeIntent -> MaryValue
preservedValue ctx intent =
    foldMap
        ( \txIn ->
            (ccUtxos ctx Map.! txIn) ^. valueTxOutL
        )
        (NE.toList (rgiTreasuryUtxos intent))

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure
