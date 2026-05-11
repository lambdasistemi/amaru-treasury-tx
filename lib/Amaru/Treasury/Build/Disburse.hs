{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.Disburse
Description : Disburse transaction build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Disburse
    ( runDisburse
    , runDisburseAction
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
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
    ( InterpretIO (..)
    , build
    , setMetadata
    )
import Cardano.Node.Client.TxBuild qualified as TxBuild
import Lens.Micro ((^.))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    , collateralInputFrom
    , indexedOutputAt
    , strictMaybe
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
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    , DisburseUsdmPayload (..)
    , disburseAdaProgram
    , disburseUsdmProgram
    )

{- | Build a disburse transaction end-to-end against a
'ChainContext'. This is the unified dispatcher branch for
feature 004; callers normally reach it via 'runBuild' /
'runFromIntent'.
-}
runDisburse
    :: ChainContext
    -> DisburseIntent
    -> Metadatum
    -- ^ CIP-1694 rationale tree (see 'Amaru.Treasury.AuxData')
    -> Addr
    -- ^ change address — also receives @collateral_return@
    --     by default (see module header)
    -> IO BuildResult
runDisburse ctx intent rationale walletAddr =
    runActionBuild BuildActionDisburse $
        runDisburseAction ctx intent rationale walletAddr

runDisburseAction
    :: ChainContext
    -> DisburseIntent
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runDisburseAction ctx intent rationale walletAddr = case intent of
    DisburseAdaIntent fields payload ->
        runDisburseAdaAction ctx fields payload rationale walletAddr
    DisburseUsdmIntent fields payload ->
        runDisburseUsdmAction ctx fields payload rationale walletAddr

-- | The ADA-disburse build pipeline.
runDisburseAdaAction
    :: ChainContext
    -> DisburseIntentFields
    -> DisburseAdaPayload
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runDisburseAdaAction ctx fields payload rationale walletAddr = do
    let walletInput = difWalletUtxo fields
        treasuryInputs = difTreasuryUtxos fields
        refInputs =
            [ difScopesDeployedAt fields
            , difPermissionsDeployedAt fields
            , difTreasuryDeployedAt fields
            , difRegistryDeployedAt fields
            ]
        utxoMap = ccUtxos ctx
        required = walletInput : treasuryInputs ++ refInputs
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletInputUtxos =
            [(walletInput, utxoMap Map.! walletInput)]
        treasuryInputUtxos =
            [ (i, utxoMap Map.! i)
            | i <- treasuryInputs
            ]
        inputUtxos =
            walletInputUtxos
                ++ treasuryInputUtxos
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <- refInputs
            ]
        pp = ccPParams ctx
    let evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        program = do
            disburseAdaProgram fields payload
            setMetadata label1694 rationale
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    (error "treasury build: unexpected context request")
    result <-
        liftIO $
            build
                pp
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
            tx <- case alignCardanoCliBuildFee pp refUtxos 2 tx0 of
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
                    , brSundaeOrderOutputs = []
                    , brTreasuryLeftoverOutput =
                        indexedOutputAt 0 body
                    , brPerChunkOverheadLovelace = Coin 0
                    , brWalletChangeOutput =
                        indexedOutputAt 2 body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

-- | The USDM-disburse build pipeline.
runDisburseUsdmAction
    :: ChainContext
    -> DisburseIntentFields
    -> DisburseUsdmPayload
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runDisburseUsdmAction ctx fields payload rationale walletAddr = do
    let walletInput = difWalletUtxo fields
        treasuryInputs = difTreasuryUtxos fields
        refInputs =
            [ difScopesDeployedAt fields
            , difPermissionsDeployedAt fields
            , difTreasuryDeployedAt fields
            , difRegistryDeployedAt fields
            ]
        utxoMap = ccUtxos ctx
        required = walletInput : treasuryInputs ++ refInputs
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletInputUtxos =
            [(walletInput, utxoMap Map.! walletInput)]
        treasuryInputUtxos =
            [ (i, utxoMap Map.! i)
            | i <- treasuryInputs
            ]
        inputUtxos =
            walletInputUtxos
                ++ treasuryInputUtxos
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <- refInputs
            ]
        pp = ccPParams ctx
    beneficiaryLovelace <-
        case usdmBeneficiaryLovelace payload treasuryInputUtxos of
            Left e ->
                throwE $
                    actionBuildError
                        BuildPhaseBuild
                        (DiagnosticChecksFailed e)
            Right ok -> pure ok
    let evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        program = do
            disburseUsdmProgram fields payload beneficiaryLovelace
            setMetadata label1694 rationale
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    (error "treasury build: unexpected context request")
    result <-
        liftIO $
            build
                pp
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
            tx <- case alignCardanoCliBuildFee pp refUtxos 2 tx0 of
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
                    , brSundaeOrderOutputs = []
                    , brTreasuryLeftoverOutput =
                        indexedOutputAt 0 body
                    , brPerChunkOverheadLovelace = Coin 0
                    , brWalletChangeOutput =
                        indexedOutputAt 2 body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

usdmBeneficiaryLovelace
    :: DisburseUsdmPayload
    -> [(a, TxOut ConwayEra)]
    -> Either T.Text Coin
usdmBeneficiaryLovelace payload treasuryInputUtxos =
    let totalInput =
            sum
                [ lovelace
                | (_, txOut) <- treasuryInputUtxos
                , let MaryValue (Coin lovelace) _ =
                        txOut ^. valueTxOutL
                ]
        Coin leftover = dupLeftoverLovelace payload
        beneficiary = totalInput - leftover
    in  if beneficiary <= 0
            then
                Left $
                    "USDM disburse beneficiary lovelace is non-positive; "
                        <> "check treasuryLeftoverLovelace against selected inputs"
            else Right (Coin beneficiary)
