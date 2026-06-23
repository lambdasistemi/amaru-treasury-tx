{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.SwapRerate
Description : Swap re-rate transaction build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Builds a cancel-and-reoffer transaction for already-selected
SundaeSwap orders against a 'ChainContext'. Discovery and high-level
operator selection happen before this runner; this module validates the
typed re-rate plan, checks the required context UTxOs, balances,
evaluates, runs final Phase-1 validation, and serializes the unsigned
transaction.
-}
module Amaru.Treasury.Build.SwapRerate
    ( runSwapRerate
    , runSwapRerateAction
    ) where

import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Tx.Build
    ( InterpretIO (..)
    , build
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    , collateralInputFrom
    , indexedOutputAt
    , indexedOutputs
    , strictMaybe
    , txIdText
    , validateFinalPhase1
    )
import Amaru.Treasury.Build.Error
    ( ActionBuildError
    , BuildAction (..)
    , BuildDiagnostic (..)
    , BuildFailurePhase (..)
    , actionBuildError
    )
import Amaru.Treasury.Build.Error.Convert
    ( diagnosticFromTxBuildError
    , missingUtxosError
    , runActionBuild
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Swap.Rerate
    ( RerateProgramInputs (..)
    , rerateProgram
    )
import Amaru.Treasury.Swap.Rerate.Plan (planRerate)
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateIntent
    , RerateScopeContext (..)
    )

-- | Build and serialize a swap re-rate transaction.
runSwapRerate
    :: ChainContext
    -> RerateProgramInputs
    -> RerateIntent
    -> IO BuildResult
runSwapRerate ctx inputs intent =
    runActionBuild BuildActionSwapRerate $
        runSwapRerateAction ctx inputs intent

-- | ExceptT form used by tests and higher-level dispatchers.
runSwapRerateAction
    :: ChainContext
    -> RerateProgramInputs
    -> RerateIntent
    -> ExceptT ActionBuildError IO BuildResult
runSwapRerateAction ctx inputs intent = do
    planned <-
        case planRerate intent of
            Left err ->
                throwE $
                    actionBuildError
                        BuildPhaseTranslate
                        (DiagnosticTranslateFailed (T.pack (show err)))
            Right ok -> pure ok
    let utxoMap = ccUtxos ctx
        orders = prOrders planned
        required =
            rpiWalletTxIn inputs
                : rpiOrderScriptRef inputs
                : rpiScopesDeployedAt inputs
                : rpiPermissionsDeployedAt inputs
                : rpiTreasuryDeployedAt inputs
                : rpiRegistryDeployedAt inputs
                : fmap proTxIn orders
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletUtxo =
            ( rpiWalletTxIn inputs
            , utxoMap Map.! rpiWalletTxIn inputs
            )
        orderUtxos =
            [ (proTxIn order, utxoMap Map.! proTxIn order)
            | order <- orders
            ]
        inputUtxos = walletUtxo : orderUtxos
        refUtxos =
            [
                ( rpiOrderScriptRef inputs
                , utxoMap Map.! rpiOrderScriptRef inputs
                )
            ,
                ( rpiScopesDeployedAt inputs
                , utxoMap Map.! rpiScopesDeployedAt inputs
                )
            ,
                ( rpiPermissionsDeployedAt inputs
                , utxoMap Map.! rpiPermissionsDeployedAt inputs
                )
            ,
                ( rpiTreasuryDeployedAt inputs
                , utxoMap Map.! rpiTreasuryDeployedAt inputs
                )
            ,
                ( rpiRegistryDeployedAt inputs
                , utxoMap Map.! rpiRegistryDeployedAt inputs
                )
            ]
        walletAddr :: Addr
        walletAddr = snd walletUtxo ^. addrTxOutL
        pp = ccPParams ctx
        evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    (error "swap-rerate build: unexpected context request")
    result <-
        liftIO $
            build
                (TxBuild.mkPParamsBound pp)
                noCtxIO
                evaluator
                inputUtxos
                refUtxos
                walletAddr
                (rerateProgram inputs planned)
    case result of
        Left e ->
            throwE $
                actionBuildError
                    BuildPhaseBuild
                    (diagnosticFromTxBuildError (e :: TxBuild.BuildError ()))
        Right tx0 -> do
            tx <-
                case alignCardanoCliBuildFee
                    pp
                    refUtxos
                    (length orders)
                    tx0 of
                    Left e ->
                        throwE $
                            actionBuildError
                                BuildPhaseFeeAlignment
                                (DiagnosticFeeAlignmentFailed (T.pack e))
                    Right ok -> pure ok
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
                        (either (Left . show) Right outcome)
                    | (purpose, outcome) <- Map.toAscList scriptMap
                    ]
                cbor =
                    serialize
                        (eraProtVerLow @ConwayEra)
                        (tx :: ConwayTx)
            pure
                BuildResult
                    { brCborBytes = cbor
                    , brFeeLovelace = feeLov
                    , brTotalCollateralLovelace = totalColl
                    , brScriptResults = scriptResults
                    , brFinalTxBody = body
                    , brTxId = txIdText tx
                    , brWalletInputs = [walletUtxo]
                    , brTreasuryInputs = []
                    , brSundaeOrderOutputs =
                        indexedOutputs 0 (length orders) body
                    , brBeneficiaryOutputs = []
                    , brTreasuryLeftoverOutput = Nothing
                    , brPerChunkOverheadLovelace =
                        rscOrderExtraLovelace (prScopeContext planned)
                    , brWalletChangeOutput =
                        indexedOutputAt (2 * length orders) body
                    , brCollateralInput =
                        collateralInputFrom body [walletUtxo]
                    , brCollateralReturn =
                        strictMaybe (body ^. collateralReturnTxBodyL)
                    , brResidualTreasuryInputs = []
                    }
