{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.OtcSwap
Description : OTC swap transaction build runner (issue #499)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Peer of "Amaru.Treasury.Build.Disburse"'s ADA pipeline: resolve the
frozen-or-live context into inputs, run 'otcSwapProgram' plus the
CIP-1694 rationale under the same fee-alignment and phase-1 gate.

One deliberate addition to the program: the @invalidBefore@ bound is
injected here as @validFrom (ccTipSlot ctx)@. The shared
'DisburseIntentFields' carries only the upper bound, and the accepted
on-chain body carries a lower bound equal to its build-time tip — so
the lower bound is build-time context, not intent data, and the
sampled tip is exactly what the runner owns.
-}
module Amaru.Treasury.Build.OtcSwap
    ( runOtcSwapAction
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
import Cardano.Tx.Build
    ( InterpretIO (..)
    , build
    , setMetadata
    , validFrom
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
import Amaru.Treasury.Tx.Disburse (DisburseIntentFields (..))
import Amaru.Treasury.Tx.OtcSwap
    ( OtcSwapIntent (..)
    , OtcSwapPayload (..)
    , otcSwapProgram
    )

{- | Build an OTC swap end-to-end against a 'ChainContext'.

The change address receives the balancing output (last index) and the
collateral return. The build itself is funding-agnostic: whoever owns
'difWalletUtxo' pays the fee and posts the collateral (spec FR-004a
rulings live in the selection policy, not here).

Output layout: counterparty (0), treasury continuing (1), change
(2). The fee delta is absorbed by the change output, never skimmed
off the counterparty (spec INV-5).
-}
runOtcSwapAction
    :: ChainContext
    -> OtcSwapIntent
    -> Metadatum
    -- ^ CIP-1694 rationale (see 'Amaru.Treasury.AuxData')
    -> Addr
    -- ^ change address — also receives @collateral_return@
    -> ExceptT ActionBuildError IO BuildResult
runOtcSwapAction ctx intent rationale walletAddr =
    case intent of
        OtcSwapIntent fields payload ->
            runOtcSwapActionWith ctx fields payload rationale walletAddr

-- | The build pipeline proper (fields and payload destructured).
runOtcSwapActionWith
    :: ChainContext
    -> DisburseIntentFields
    -> OtcSwapPayload
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO BuildResult
runOtcSwapActionWith ctx fields payload rationale walletAddr = do
    let walletInput = difWalletUtxo fields
        treasuryInputs = difTreasuryUtxos fields
        counterpartyInput = ospCounterpartyUtxo payload
        refInputs =
            [ difScopesDeployedAt fields
            , difPermissionsDeployedAt fields
            , difTreasuryDeployedAt fields
            , difRegistryDeployedAt fields
            ]
        utxoMap = ccUtxos ctx
        required =
            walletInput : counterpartyInput : treasuryInputs ++ refInputs
        missing =
            [ i
            | i <- required
            , not (Map.member i utxoMap)
            ]
    unless (null missing) $
        throwE (missingUtxosError missing)
    let walletInputUtxos =
            [(walletInput, utxoMap Map.! walletInput)]
        counterpartyInputUtxos =
            [(counterpartyInput, utxoMap Map.! counterpartyInput)]
        treasuryInputUtxos =
            [ (i, utxoMap Map.! i)
            | i <- treasuryInputs
            ]
        inputUtxos =
            walletInputUtxos
                ++ counterpartyInputUtxos
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
            -- Lower validity bound = sampled tip (see module header).
            validFrom (ccTipSlot ctx)
            otcSwapProgram fields payload
            setMetadata label1694 rationale
        -- Output layout: counterparty (0), treasury (1), change (2).
        changeIx :: Int
        changeIx = 2
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
            tx <- case alignCardanoCliBuildFee pp refUtxos changeIx tx0 of
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
                    , brBeneficiaryOutputs =
                        indexedOutputs 0 1 body
                    , brTreasuryLeftoverOutput =
                        indexedOutputAt 1 body
                    , brPerChunkOverheadLovelace = Coin 0
                    , brWalletChangeOutput =
                        indexedOutputAt changeIx body
                    , brCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , brCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    , brResidualTreasuryInputs = []
                    }
