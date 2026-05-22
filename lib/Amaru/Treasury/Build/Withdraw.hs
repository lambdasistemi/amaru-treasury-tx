{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.Withdraw
Description : Withdraw transaction build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Withdraw
    ( runWithdraw
    , runWithdrawAction
    , addWithdrawalToChange
    ) where

import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , outputsTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Tx.Build
    ( InterpretIO (..)
    , build
    , setMetadata
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((&), (.~), (^.))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    , collateralInputFrom
    , indexedOutputAt
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
import Amaru.Treasury.Tx.Withdraw
    ( WithdrawIntent (..)
    , withdrawProgram
    )

{- | Build a withdraw transaction end-to-end against a
'ChainContext'. The dispatcher is wired in T037; the full
build pipeline lands in T038.
-}
runWithdraw
    :: ChainContext
    -> WithdrawIntent
    -> Metadatum
    -- ^ CIP-1694 rationale tree (see 'Amaru.Treasury.AuxData')
    -> Addr
    -- ^ change address — also receives @collateral_return@
    --     by default (see module header)
    -> IO BuildResult
runWithdraw ctx intent rationale walletAddr =
    runActionBuild BuildActionWithdraw $
        runWithdrawAction ctx intent rationale walletAddr

runWithdrawAction
    :: ChainContext
    -> WithdrawIntent
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runWithdrawAction ctx intent rationale walletAddr = do
    let walletInput = wiWalletUtxo intent
        refInputs =
            [ wiTreasuryDeployedAt intent
            , wiRegistryDeployedAt intent
            ]
        utxoMap = ccUtxos ctx
        required = walletInput : refInputs
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletInputUtxos =
            [(walletInput, utxoMap Map.! walletInput)]
        inputUtxos = walletInputUtxos
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <- refInputs
            ]
        pp = ccPParams ctx
        -- withdrawProgram emits the treasury rewards output first;
        -- the balancer appends wallet change after it.
        changeOutputIndex = 1
    let evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        program = do
            withdrawProgram intent
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
            txWithWithdrawal <-
                case addWithdrawalToChange
                    changeOutputIndex
                    (wiRewardsAmount intent)
                    tx0 of
                    Left e ->
                        throwE $
                            actionBuildError
                                BuildPhaseFeeAlignment
                                (DiagnosticFeeAlignmentFailed (T.pack e))
                    Right ok -> pure ok
            tx <-
                case alignCardanoCliBuildFee
                    pp
                    refUtxos
                    changeOutputIndex
                    txWithWithdrawal of
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
                    , brWalletChangeOutput =
                        indexedOutputAt changeOutputIndex body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    , brResidualTreasuryInputs = []
                    }

addWithdrawalToChange
    :: Int -> Coin -> ConwayTx -> Either String ConwayTx
addWithdrawalToChange changeIx (Coin rewards) tx =
    case splitAt changeIx (toList (tx ^. bodyTxL . outputsTxBodyL)) of
        (_, []) ->
            Left "change output index out of range"
        (before, changeOut : after) ->
            let Coin current = changeOut ^. coinTxOutL
                outputs' =
                    StrictSeq.fromList $
                        before
                            ++ [ changeOut
                                    & coinTxOutL
                                        .~ Coin (current + rewards)
                               ]
                            ++ after
            in  Right $
                    tx
                        & bodyTxL . outputsTxBodyL
                            .~ outputs'
