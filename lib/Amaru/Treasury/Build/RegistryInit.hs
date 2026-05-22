{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.RegistryInit
Description : Registry-init sub-action build runners
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per-sub-action dispatcher arms for the three flat
@registry-init-*@ intents. Each runner pulls the input UTxOs
out of the supplied 'ChainContext', derives any auxiliary
script material needed, then invokes the matching
construction core in "Amaru.Treasury.Devnet.RegistryInit" so
the live DevNet submitter and the offline @tx-build@
pipeline produce byte-identical unsigned transactions.

Bootstrap registry-init programs do not call @setMetadata@,
so the @rationale@ field on the shared translated record is
unused by these runners.
-}
module Amaru.Treasury.Build.RegistryInit
    ( runRegistryInitSeedSplitAction
    , runRegistryInitMintAction
    , runRegistryInitReferenceScriptsAction
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
import Amaru.Treasury.Devnet.RegistryInit
    ( CoreEvaluator
    , buildReferenceScriptsCore
    , buildRegistryNftsCore
    , buildSeedSplitCore
    , deriveDevnetScripts
    )
import Amaru.Treasury.IntentJSON
    ( RegistryInitMintTx (..)
    , RegistryInitReferenceScriptsTx (..)
    , RegistryInitSeedSplitTx (..)
    )

-- | Build a @registry-init-seed-split@ transaction.
runRegistryInitSeedSplitAction
    :: ChainContext
    -> RegistryInitSeedSplitTx
    -> ExceptT ActionBuildError IO BuildResult
runRegistryInitSeedSplitAction ctx tx = do
    seed <- requireUtxo ctx (risstSeedTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
            buildSeedSplitCore
                (ccPParams ctx)
                (risstFundingAddress tx)
                (risstUpperBoundSlot tx)
                seed
                eval
    materializeResult ctx walletInputUtxos txResult

-- | Build a @registry-init-mint@ transaction.
runRegistryInitMintAction
    :: ChainContext
    -> RegistryInitMintTx
    -> ExceptT ActionBuildError IO BuildResult
runRegistryInitMintAction ctx tx = do
    scopesSeed <- requireUtxo ctx (rimtScopesSeedTxIn tx)
    registrySeed <- requireUtxo ctx (rimtRegistrySeedTxIn tx)
    scripts <-
        liftIO $
            deriveDevnetScripts
                (rimtNetwork tx)
                (rimtScopesSeedTxIn tx)
                (rimtRegistrySeedTxIn tx)
    let walletInputUtxos = [scopesSeed, registrySeed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
            buildRegistryNftsCore
                (ccPParams ctx)
                (rimtFundingAddress tx)
                (rimtNetwork tx)
                (rimtOwnerKeyHash tx)
                scripts
                (rimtUpperBoundSlot tx)
                walletInputUtxos
                eval
    materializeResult ctx walletInputUtxos txResult

-- | Build a @registry-init-reference-scripts@ transaction.
runRegistryInitReferenceScriptsAction
    :: ChainContext
    -> RegistryInitReferenceScriptsTx
    -> ExceptT ActionBuildError IO BuildResult
runRegistryInitReferenceScriptsAction ctx tx = do
    seed <- requireUtxo ctx (rirstSeedTxIn tx)
    scripts <-
        liftIO $
            deriveDevnetScripts
                (rirstNetwork tx)
                (rirstScopesSeedTxIn tx)
                (rirstRegistrySeedTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
            buildReferenceScriptsCore
                (ccPParams ctx)
                (rirstFundingAddress tx)
                scripts
                (rirstUpperBoundSlot tx)
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

Registry-init transactions never aggregate Sundae order
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
                    , brResidualTreasuryInputs = []
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
