{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.StakeRewardInit
Description : Stake-reward-init sub-action build runners
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per-sub-action dispatcher arms for the two flat
@stake-reward-init-*@ intents. Each runner pulls the
funding seed (and, for the script-account variant, the
treasury reference-script UTxO) from the supplied
'ChainContext', then invokes the matching construction
core in "Amaru.Treasury.Devnet.StakeRewardInit" so the
live DevNet submitter and the offline @tx-build@ pipeline
produce byte-identical unsigned transactions for each
sub-action.

Stake-reward registrations do not call @setMetadata@, so
the @rationale@ field on the shared translated record is
unused by these runners.
-}
module Amaru.Treasury.Build.StakeRewardInit
    ( runStakeRewardInitScriptAccountAction
    , runStakeRewardInitPlainAccountAction
    ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE)
import Data.Map.Strict qualified as Map
import Data.Void (Void, absurd)

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Amaru.Treasury.Build.Common
    ( collateralInputFrom
    , strictMaybe
    , txIdText
    , validateFinalPhase1
    )
import Amaru.Treasury.Build.Error
    ( ActionBuildError
    , BuildDiagnostic (..)
    , BuildFailurePhase (..)
    , actionBuildError
    )
import Amaru.Treasury.Build.Error.Convert
    ( diagnosticFromTxBuildError
    , missingUtxosError
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Devnet.StakeRewardInit
    ( CoreEvaluator
    , buildStakeRewardPlainAccountCore
    , buildStakeRewardScriptAccountCore
    )
import Amaru.Treasury.IntentJSON
    ( StakeRewardInitPlainAccountTx (..)
    , StakeRewardInitScriptAccountTx (..)
    )

-- | Build a @stake-reward-init-script-account@ transaction.
runStakeRewardInitScriptAccountAction
    :: ChainContext
    -> StakeRewardInitScriptAccountTx
    -> ExceptT ActionBuildError IO BuildResult
runStakeRewardInitScriptAccountAction ctx tx = do
    seed <- requireUtxo ctx (srisatSeedTxIn tx)
    treasuryRefUtxo <- requireUtxo ctx (srisatTreasuryRefTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
            buildStakeRewardScriptAccountCore
                (ccPParams ctx)
                (srisatFundingAddress tx)
                (srisatTreasuryCredential tx)
                (srisatTreasuryRefTxIn tx)
                (srisatUpperBoundSlot tx)
                seed
                treasuryRefUtxo
                eval
    materializeResult ctx walletInputUtxos txResult

-- | Build a @stake-reward-init-plain-account@ transaction.
runStakeRewardInitPlainAccountAction
    :: ChainContext
    -> StakeRewardInitPlainAccountTx
    -> ExceptT ActionBuildError IO BuildResult
runStakeRewardInitPlainAccountAction ctx tx = do
    seed <- requireUtxo ctx (srispatSeedTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
            buildStakeRewardPlainAccountCore
                (ccPParams ctx)
                (srispatFundingAddress tx)
                (srispatPermissionsCredential tx)
                (srispatUpperBoundSlot tx)
                seed
                eval
    materializeResult ctx walletInputUtxos txResult

-- | Resolve a TxIn against the ChainContext UTxO map.
requireUtxo
    :: ChainContext
    -> TxIn
    -> ExceptT ActionBuildError IO (TxIn, TxOut ConwayEra)
requireUtxo ctx ref =
    case Map.lookup ref (ccUtxos ctx) of
        Just out -> pure (ref, out)
        Nothing -> throwE (missingUtxosError [ref])

{- | Wrap the ChainContext evaluator into the
'Cardano.Tx.Build.build' contract.
-}
chainContextEvaluator :: ChainContext -> CoreEvaluator
chainContextEvaluator ctx tx = do
    m <- ccEvaluateTx ctx tx
    pure (Map.map (either (Left . show) Right) m)

{- | Common projection from a built 'ConwayTx' to the
'BuildResult' the dispatcher hands back to the caller.

Stake-reward-init transactions never aggregate Sundae order
outputs, treasury leftover outputs, or per-chunk operator
overhead, so those rows are left empty.
-}
materializeResult
    :: ChainContext
    -> [(TxIn, TxOut ConwayEra)]
    -> Either (TxBuild.BuildError Void) ConwayTx
    -> ExceptT ActionBuildError IO BuildResult
materializeResult ctx walletInputUtxos result =
    case result of
        Left e ->
            throwE $
                actionBuildError
                    BuildPhaseBuild
                    (diagnosticFromTxBuildErrorVoid e)
        Right tx -> do
            case validateFinalPhase1 ctx tx of
                Left e ->
                    throwE $
                        actionBuildError
                            BuildPhaseBuild
                            (DiagnosticChecksFailed e)
                Right () -> pure ()
            let body = tx ^. bodyTxL
                feeLov = body ^. feeTxBodyL
                totalColl = case body
                    ^. totalCollateralTxBodyL of
                    SJust c -> c
                    SNothing -> Coin 0
            scriptMap <- liftIO $ ccEvaluateTx ctx tx
            let scriptResults =
                    [ ScriptResult
                        purpose
                        ( either
                            (Left . show)
                            Right
                            outcome
                        )
                    | (purpose, outcome) <-
                        Map.toAscList scriptMap
                    ]
                cbor =
                    serialize
                        (eraProtVerLow @ConwayEra)
                        (tx :: ConwayTx)
            pure
                BuildResult
                    { brCborBytes = cbor
                    , brFeeLovelace = feeLov
                    , brTotalCollateralLovelace =
                        totalColl
                    , brScriptResults = scriptResults
                    , brFinalTxBody = body
                    , brTxId = txIdText tx
                    , brWalletInputs = walletInputUtxos
                    , brTreasuryInputs = []
                    , brSundaeOrderOutputs = []
                    , brTreasuryLeftoverOutput = Nothing
                    , brPerChunkOverheadLovelace = Coin 0
                    , brWalletChangeOutput = Nothing
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

{- | Lift a Void-error 'BuildError' from the construction
core into the project's diagnostic ADT. The construction
cores use @TxBuild.BuildError Void@ because their programs
emit no application-level errors; the conversion drops the
unreachable error constructor.
-}
diagnosticFromTxBuildErrorVoid
    :: TxBuild.BuildError Void
    -> BuildDiagnostic
diagnosticFromTxBuildErrorVoid =
    diagnosticFromTxBuildError . coerceBuildError

coerceBuildError
    :: TxBuild.BuildError Void
    -> TxBuild.BuildError ()
coerceBuildError = \case
    TxBuild.EvalFailure purpose reason ->
        TxBuild.EvalFailure purpose reason
    TxBuild.BalanceFailed err ->
        TxBuild.BalanceFailed err
    TxBuild.ChecksFailed checks ->
        TxBuild.ChecksFailed (fmap coerceCheck checks)
    TxBuild.BumpFeeFailed err ->
        TxBuild.BumpFeeFailed err

coerceCheck :: TxBuild.Check Void -> TxBuild.Check ()
coerceCheck = \case
    TxBuild.Pass -> TxBuild.Pass
    TxBuild.LedgerFail err -> TxBuild.LedgerFail err
    TxBuild.CustomFail v -> absurd v
