{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.GovernanceWithdrawalInit
Description : Governance-withdrawal-init sub-action build runners
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Per-sub-action dispatcher arms for the two flat
@governance-withdrawal-init-*@ intents. Each runner pulls
the funding seed (and, for the materialization variant,
the treasury and registry reference-script UTxOs) from the
supplied 'ChainContext', then invokes the matching
construction core in
"Amaru.Treasury.Devnet.GovernanceWithdrawalInit" so the
live DevNet submitter and the offline @tx-build@ pipeline
produce byte-identical unsigned transactions for each
sub-action.

The bootstrap proposal and materialization programs do not
call @setMetadata@, so the @rationale@ field on the shared
translated record is unused by these runners.
-}
module Amaru.Treasury.Build.GovernanceWithdrawalInit
    ( runGovernanceWithdrawalInitProposalAction
    , runGovernanceWithdrawalInitMaterializationAction
    ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Void (Void, absurd)

import Cardano.Ledger.Address
    ( AccountAddress
    , Withdrawals (..)
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ApplyTxError (..), ConwayEra)
import Cardano.Ledger.Conway.Rules (ConwayLedgerPredFailure)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate
    ( isWitnessCompletenessFailure
    , validatePhase1WithRewardAccounts
    )
import Lens.Micro ((^.))

import Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    , collateralInputFrom
    , strictMaybe
    , txIdText
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
import Amaru.Treasury.Build.Withdraw
    ( addWithdrawalToChange
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( GovernanceWithdrawalCoreEvaluator
    , buildGovernanceWithdrawalMaterializationCore
    , buildGovernanceWithdrawalProposalCore
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitMaterializationTx (..)
    , GovernanceWithdrawalInitProposalTx (..)
    )

-- | Build a @governance-withdrawal-init-proposal@ transaction.
runGovernanceWithdrawalInitProposalAction
    :: ChainContext
    -> GovernanceWithdrawalInitProposalTx
    -> ExceptT ActionBuildError IO BuildResult
runGovernanceWithdrawalInitProposalAction ctx tx = do
    seed <- requireUtxo ctx (gwiptSeedTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
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
                eval
    materializeProposalResult ctx tx walletInputUtxos txResult

-- | Build a @governance-withdrawal-init-materialization@ transaction.
runGovernanceWithdrawalInitMaterializationAction
    :: ChainContext
    -> GovernanceWithdrawalInitMaterializationTx
    -> ExceptT ActionBuildError IO BuildResult
runGovernanceWithdrawalInitMaterializationAction ctx tx = do
    seed <- requireUtxo ctx (gwimtSeedTxIn tx)
    treasuryRefUtxo <-
        requireUtxo ctx (gwimtTreasuryRefTxIn tx)
    registryRefUtxo <-
        requireUtxo ctx (gwimtRegistryRefTxIn tx)
    let walletInputUtxos = [seed]
        eval = chainContextEvaluator ctx
    txResult <-
        liftIO $
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
                eval
    case txResult of
        Left{} ->
            materializeResult ctx walletInputUtxos txResult
        Right tx0 -> do
            let changeOutputIndex = 1
                refUtxos = [treasuryRefUtxo, registryRefUtxo]
            txWithWithdrawal <-
                case addWithdrawalToChange
                    changeOutputIndex
                    (gwimtRewardsAmount tx)
                    tx0 of
                    Left e ->
                        throwE $
                            actionBuildError
                                BuildPhaseFeeAlignment
                                (DiagnosticFeeAlignmentFailed (T.pack e))
                    Right ok -> pure ok
            alignedTx <-
                case alignCardanoCliBuildFee
                    (ccPParams ctx)
                    refUtxos
                    changeOutputIndex
                    txWithWithdrawal of
                    Left e ->
                        throwE $
                            actionBuildError
                                BuildPhaseFeeAlignment
                                (DiagnosticFeeAlignmentFailed (T.pack e))
                    Right ok -> pure ok
            materializeResult ctx walletInputUtxos (Right alignedTx)

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
chainContextEvaluator
    :: ChainContext
    -> GovernanceWithdrawalCoreEvaluator
chainContextEvaluator ctx tx = do
    m <- ccEvaluateTx ctx tx
    pure (Map.map (either (Left . show) Right) m)

{- | Common projection from a built 'ConwayTx' to the
'BuildResult' the dispatcher hands back to the caller.

Governance-withdrawal-init transactions never aggregate
Sundae order outputs, treasury leftover outputs, or
per-chunk operator overhead, so those rows are left empty.
-}
materializeResult
    :: ChainContext
    -> [(TxIn, TxOut ConwayEra)]
    -> Either (TxBuild.BuildError Void) ConwayTx
    -> ExceptT ActionBuildError IO BuildResult
materializeResult ctx =
    materializeResultImpl (validateMaterializationPhase1 ctx) ctx

materializeProposalResult
    :: ChainContext
    -> GovernanceWithdrawalInitProposalTx
    -> [(TxIn, TxOut ConwayEra)]
    -> Either (TxBuild.BuildError Void) ConwayTx
    -> ExceptT ActionBuildError IO BuildResult
materializeProposalResult ctx proposalTx =
    materializeResultImpl
        (validateProposalPhase1 ctx proposalTx)
        ctx

materializeResultImpl
    :: (ConwayTx -> Either T.Text ())
    -> ChainContext
    -> [(TxIn, TxOut ConwayEra)]
    -> Either (TxBuild.BuildError Void) ConwayTx
    -> ExceptT ActionBuildError IO BuildResult
materializeResultImpl validatePhase1 ctx walletInputUtxos result =
    case result of
        Left e ->
            throwE $
                actionBuildError
                    BuildPhaseBuild
                    (diagnosticFromTxBuildErrorVoid e)
        Right tx -> do
            case validatePhase1 tx of
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

validateProposalPhase1
    :: ChainContext
    -> GovernanceWithdrawalInitProposalTx
    -> ConwayTx
    -> Either T.Text ()
validateProposalPhase1 ctx proposalTx =
    validateRewardAwarePhase1
        ctx
        (proposalRewardAccounts proposalTx)

validateMaterializationPhase1
    :: ChainContext
    -> ConwayTx
    -> Either T.Text ()
validateMaterializationPhase1 ctx tx =
    validateRewardAwarePhase1
        ctx
        (withdrawalRewardAccounts tx)
        tx

validateRewardAwarePhase1
    :: ChainContext
    -> Map.Map AccountAddress Coin
    -> ConwayTx
    -> Either T.Text ()
validateRewardAwarePhase1 ctx rewardAccounts tx =
    case validatePhase1WithRewardAccounts
        (ccNetwork ctx)
        (TxBuild.mkPParamsBound (ccPParams ctx))
        (Map.toList (ccUtxos ctx))
        rewardAccounts
        (ccTipSlot ctx)
        tx of
        Right () -> Right ()
        Left err ->
            let structural =
                    filter
                        (not . isWitnessCompletenessFailure)
                        (phase1Failures err)
            in  if null structural
                    then Right ()
                    else
                        Left $
                            "Phase-1 validation rejected final transaction at sampled slot "
                                <> T.pack (show (ccTipSlot ctx))
                                <> ": "
                                <> T.pack (show structural)

proposalRewardAccounts
    :: GovernanceWithdrawalInitProposalTx
    -> Map.Map AccountAddress Coin
proposalRewardAccounts tx =
    -- The proposal transaction registers its return account in
    -- the same body, so only seed the pre-existing treasury
    -- account state here.
    Map.fromList
        [ (gwiptTreasuryAccount tx, Coin 0)
        ]

withdrawalRewardAccounts :: ConwayTx -> Map.Map AccountAddress Coin
withdrawalRewardAccounts tx =
    let Withdrawals withdrawals = tx ^. bodyTxL . withdrawalsTxBodyL
    in  withdrawals

phase1Failures
    :: ApplyTxError ConwayEra
    -> [ConwayLedgerPredFailure ConwayEra]
phase1Failures (ConwayApplyTxError errs) = toList errs

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
