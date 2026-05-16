{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.Swap
Description : Swap transaction build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Swap
    ( runSwap
    , runSwapAction
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
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build
    ( InterpretIO (..)
    , build
    , setMetadata
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Amaru.Treasury.AuxData (label1694)
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
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , swapProgram
    )

{- | Build a swap transaction end-to-end against a
'ChainContext'. The context carries the only inputs the
build is allowed to read from "reality" (pparams,
UTxOs, script evaluator); supplying a frozen one
('Amaru.Treasury.ChainContext.frozenContext') makes the
build deterministic across chain drift.

This is the low-level driver; callers that already have
a typed 'TreasuryIntent' can reach it via 'runBuild' /
'runFromIntent'. Direct callers ('app/swap-probe',
'app/capture-swap-context') stitch the inputs together
manually for parity tooling.
-}
runSwap
    :: ChainContext
    -> SwapIntent
    -> Metadatum
    -- ^ CIP-1694 rationale tree (see 'Amaru.Treasury.AuxData')
    -> TxIn
    -- ^ the wallet UTxO used as fuel + collateral
    -> Addr
    -- ^ change address — also receives @collateral_return@
    --     by default (see module header)
    -> IO BuildResult
runSwap ctx intent rationale walletInput walletAddr =
    runActionBuild BuildActionSwap $
        runSwapAction ctx intent rationale walletInput walletAddr

runSwapAction
    :: ChainContext
    -> SwapIntent
    -> Metadatum
    -> TxIn
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runSwapAction ctx intent rationale walletInput walletAddr = do
    let utxoMap = ccUtxos ctx
        required =
            walletInput
                : siExtraWalletInputs intent
                ++ siTreasuryUtxos intent
                ++ [ siScopesDeployedAt intent
                   , siPermissionsDeployedAt intent
                   , siTreasuryDeployedAt intent
                   , siRegistryDeployedAt intent
                   ]
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletInputUtxos =
            (walletInput, utxoMap Map.! walletInput)
                : [ (i, utxoMap Map.! i)
                  | i <- siExtraWalletInputs intent
                  ]
        treasuryInputUtxos =
            [ (i, utxoMap Map.! i)
            | i <- siTreasuryUtxos intent
            ]
        inputUtxos = walletInputUtxos ++ treasuryInputUtxos
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <-
                [ siScopesDeployedAt intent
                , siPermissionsDeployedAt intent
                , siTreasuryDeployedAt intent
                , siRegistryDeployedAt intent
                ]
            ]
        pp = ccPParams ctx
    let evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        program = do
            swapProgram intent
            setMetadata label1694 rationale
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    (error "treasury build: unexpected context request")
    result <-
        liftIO $
            build
                (TxBuild.mkPParamsBound pp)
                noCtxIO
                evaluator
                inputUtxos
                refUtxos
                walletAddr
                program
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
                    (length (siSwapOrders intent) + 1)
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
            -- Re-evaluate on the final tx so callers
            -- see the per-redeemer outcome alongside
            -- the CBOR. The closure passed to 'build'
            -- above drove the balancing fixpoint; this
            -- second call captures script results once
            -- the body is settled.
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
                    , brTreasuryInputs = treasuryInputUtxos
                    , brSundaeOrderOutputs =
                        indexedOutputs
                            0
                            (length (siSwapOrders intent))
                            body
                    , brTreasuryLeftoverOutput =
                        indexedOutputAt
                            (length (siSwapOrders intent))
                            body
                    , brPerChunkOverheadLovelace =
                        siSwapOrderExtraLovelace intent
                    , brWalletChangeOutput =
                        indexedOutputAt
                            (length (siSwapOrders intent) + 1)
                            body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }
