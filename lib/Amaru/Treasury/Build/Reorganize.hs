{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.Reorganize
Description : Reorganize transaction build runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Reorganize
    ( runReorganizeBuild
    , runReorganizeAction
    ) where

import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, throwE)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.Metadata (Metadatum)
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
import Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    , reorganizeProgram
    )

{- | Build a reorganize transaction end-to-end against a
'ChainContext'.
-}
runReorganizeBuild
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -- ^ CIP-1694 rationale tree.
    -> Addr
    -- ^ Change address.
    -> IO BuildResult
runReorganizeBuild ctx intent rationale walletAddr =
    runActionBuild BuildActionReorganize $
        runReorganizeAction ctx intent rationale walletAddr

-- | Low-level action runner used by direct tests and the dispatcher.
runReorganizeAction
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runReorganizeAction ctx intent rationale walletAddr = do
    let walletInput = rgiWalletUtxo intent
        treasuryInputs = NE.toList (rgiTreasuryUtxos intent)
        refInputs =
            [ rgiTreasuryDeployedAt intent
            , rgiRegistryDeployedAt intent
            , rgiPermissionsDeployedAt intent
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
    unless
        (allTreasuryInputsAtAddress intent treasuryInputUtxos)
        ( throwE $
            actionBuildError
                BuildPhaseGatherInputs
                ( DiagnosticChecksFailed $
                    T.pack
                        "reorganize treasuryUtxos must all live at treasuryAddress"
                )
        )
    let
        inputUtxos = walletInputUtxos ++ treasuryInputUtxos
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <- refInputs
            ]
        pp = ccPParams ctx
        preservedValue = preservedTreasuryValue treasuryInputUtxos
        -- reorganizeProgram emits the continuing treasury output first;
        -- the balancer appends wallet change after it.
        changeOutputIndex = 1
    let evaluator tx = do
            m <- ccEvaluateTx ctx tx
            pure (fmap (either (Left . show) Right) m)
        program = do
            reorganizeProgram intent preservedValue
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
                    changeOutputIndex
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
                        indexedOutputAt changeOutputIndex body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

preservedTreasuryValue
    :: [(a, TxOut ConwayEra)]
    -> MaryValue
preservedTreasuryValue =
    foldMap ((^. valueTxOutL) . snd)

allTreasuryInputsAtAddress
    :: ReorganizeIntent -> [(a, TxOut ConwayEra)] -> Bool
allTreasuryInputsAtAddress intent =
    all ((== rgiTreasuryAddress intent) . (^. addrTxOutL) . snd)
