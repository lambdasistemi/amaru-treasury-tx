{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.SwapCancel
Description : SundaeSwap order cancellation build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Builds one explicit SundaeSwap order cancellation against a
'ChainContext'. Discovery of candidate orders and datum validation are
caller responsibilities; this module only balances, evaluates, and
serializes the already-selected cancellation intent.
-}
module Amaru.Treasury.Build.SwapCancel
    ( runSwapCancel
    , runSwapCancelAction
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
    , txIdText
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
import Amaru.Treasury.Tx.SwapCancel
    ( SwapCancelIntent (..)
    , swapCancelProgram
    )

-- | Build and serialize one explicit SundaeSwap order cancellation.
runSwapCancel :: ChainContext -> SwapCancelIntent -> IO BuildResult
runSwapCancel ctx intent =
    runActionBuild BuildActionSwapCancel $
        runSwapCancelAction ctx intent

-- | ExceptT form used by tests and higher-level dispatchers.
runSwapCancelAction
    :: ChainContext
    -> SwapCancelIntent
    -> ExceptT ActionBuildError IO BuildResult
runSwapCancelAction ctx intent = do
    let utxoMap = ccUtxos ctx
        required =
            [ sciWalletTxIn intent
            , sciOrderTxIn intent
            , sciOrderScriptRef intent
            ]
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletUtxo =
            (sciWalletTxIn intent, utxoMap Map.! sciWalletTxIn intent)
        orderUtxo =
            (sciOrderTxIn intent, utxoMap Map.! sciOrderTxIn intent)
        scriptRefUtxo =
            ( sciOrderScriptRef intent
            , utxoMap Map.! sciOrderScriptRef intent
            )
        inputUtxos = [walletUtxo, orderUtxo]
        refUtxos = [scriptRefUtxo]
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
                    (error "swap-cancel build: unexpected context request")
    result <-
        liftIO $
            build
                pp
                noCtxIO
                evaluator
                inputUtxos
                refUtxos
                walletAddr
                (swapCancelProgram intent)
    case result of
        Left e ->
            throwE $
                actionBuildError
                    BuildPhaseBuild
                    (diagnosticFromTxBuildError (e :: TxBuild.BuildError ()))
        Right tx0 -> do
            tx <-
                case alignCardanoCliBuildFee pp refUtxos 1 tx0 of
                    Left e ->
                        throwE $
                            actionBuildError
                                BuildPhaseFeeAlignment
                                (DiagnosticFeeAlignmentFailed (T.pack e))
                    Right ok -> pure ok
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
                    , brTotalCollateralLovelace = totalColl
                    , brScriptResults = scriptResults
                    , brFinalTxBody = body
                    , brTxId = txIdText tx
                    , brWalletInputs = [walletUtxo]
                    , brTreasuryInputs = []
                    , brSundaeOrderOutputs = []
                    , brTreasuryLeftoverOutput =
                        indexedOutputAt 0 body
                    , brPerChunkOverheadLovelace = Coin 0
                    , brWalletChangeOutput =
                        indexedOutputAt 1 body
                    , brCollateralInput =
                        collateralInputFrom body [walletUtxo]
                    , brCollateralReturn =
                        case body ^. collateralReturnTxBodyL of
                            SNothing -> Nothing
                            SJust out -> Just out
                    }
