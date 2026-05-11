{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Amaru.Treasury.TreasuryBuild
Description : Unified IO build pipeline (action-polymorphic)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single dispatcher that consumes a 'SomeTreasuryIntent'
or a typed @'TreasuryIntent' a@ and runs the matching
per-action build pipeline. Keeps the pure builders
('Tx.Swap.swapProgram',
'Tx.Disburse.disburseAdaProgram', …) untouched —
'runBuild' is just the IO seam that selects which one to
call.

Threads the chosen pure program through a
[`Cardano.Node.Client.TxBuild.build`](https://github.com/lambdasistemi/cardano-node-clients)
loop with the live script evaluator. Since
[lambdasistemi/cardano-node-clients#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124)
@build@ emits Conway @total_collateral@ (CBOR key 17)
and @collateral_return@ (key 16) inside the fee
fixpoint, defaulting the return target to the same
change address passed to @build@. The wallet UTxO
doubles as fuel and collateral, so the default is
correct here and no @setCollateralReturn@ override is
needed.

The final tx is re-evaluated against the script
evaluator so callers get a per-redeemer outcome
('tbrScriptResults') alongside the CBOR.

In this phase-4 cut the swap, disburse, and withdraw
branches are wired. Reorganize lands with
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46).
-}
module Amaru.Treasury.TreasuryBuild
    ( -- * Outputs
      BuildDiagnostic (..)
    , BuildErrorContext (..)
    , BuildFailurePhase (..)
    , TreasuryBuildAction (..)
    , TreasuryBuildError (..)
    , TreasuryBuildException (..)
    , TreasuryBuildResult (..)
    , ScriptResult (..)

      -- * Drivers
    , runBuild
    , runFromIntent
    , runFromIntentEither
    , runDisburse
    , runSwap
    , runWithdraw

      -- * Diagnostics
    , mapTreasuryBuildExceptionContext
    , renderTreasuryBuildError
    , treasuryBuildErrorCode
    , treasuryBuildErrorFromBuildError
    , withBuildErrorContext
    , withTreasuryBuildExceptionContext
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Control.Exception
    ( Exception (..)
    , throwIO
    , try
    )
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
    ( ExceptT
    , runExceptT
    , throwE
    , withExceptT
    )
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (estimateMinFeeTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( Withdrawals (..)
    , collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , totalCollateralTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams, TopTx, TxBody, bodyTxL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Node.Client.Balance
    ( BalanceError (..)
    , refScriptsSize
    )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
    ( BuildError (..)
    , InterpretIO (..)
    , build
    , setMetadata
    )
import Lens.Micro ((&), (.~), (^.))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , Translated
    , TranslatedShared (..)
    , translateIntent
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    , disburseAdaProgram
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , swapProgram
    )
import Amaru.Treasury.Tx.Withdraw
    ( WithdrawIntent (..)
    , withdrawProgram
    )

-- | Per-script result from 'evaluateTx'.
data ScriptResult = ScriptResult
    { srPurpose
        :: !( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
    , srOutcome :: !(Either String ExUnits)
    -- ^ @Right ex@ on success carrying the evaluator's
    --     ExUnits; @Left e@ on script failure.
    }
    deriving (Show)

-- | What the build pipeline returns.
data TreasuryBuildResult = TreasuryBuildResult
    { tbrCborBytes :: !BSL.ByteString
    -- ^ raw Conway tx CBOR
    , tbrFeeLovelace :: !Coin
    -- ^ fee assigned by 'build'
    , tbrTotalCollateralLovelace :: !Coin
    -- ^ @total_collateral@ as recorded in the final
    --     body. 'Coin' 0 if the body has no
    --     @total_collateral@ field (a non-script tx).
    , tbrScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced tx
    , tbrFinalTxBody :: !(TxBody TopTx ConwayEra)
    -- ^ final balanced transaction body used to render
    --     deterministic reports without rebuilding
    , tbrTxId :: !Text
    -- ^ transaction id of the final balanced transaction
    , tbrWalletInputs :: ![(TxIn, TxOut ConwayEra)]
    -- ^ wallet-owned inputs used to fuel the build
    , tbrTreasuryInputs :: ![(TxIn, TxOut ConwayEra)]
    -- ^ treasury-owned inputs spent by the build
    , tbrSundaeOrderOutputs :: ![(Int, TxOut ConwayEra)]
    -- ^ final Sundae order outputs, paired with ledger output indexes
    , tbrTreasuryLeftoverOutput :: !(Maybe (Int, TxOut ConwayEra))
    -- ^ final treasury leftover output, when present
    , tbrPerChunkOverheadLovelace :: !Coin
    -- ^ per-order overhead funded by the treasury for swap builds
    , tbrWalletChangeOutput :: !(Maybe (Int, TxOut ConwayEra))
    -- ^ final wallet change output, paired with its output index
    , tbrCollateralInput :: !(Maybe (TxIn, TxOut ConwayEra))
    -- ^ wallet input selected as collateral, when present
    , tbrCollateralReturn :: !(Maybe (TxOut ConwayEra))
    -- ^ collateral-return output from the final body, when present
    }

-- | Treasury action whose build path produced a diagnostic.
data TreasuryBuildAction
    = BuildActionSwap
    | BuildActionDisburse
    | BuildActionWithdraw
    | BuildActionReorganize
    | BuildActionIntent
    deriving stock (Eq, Show)

-- | Coarse phase where an expected build failure occurred.
data BuildFailurePhase
    = BuildPhaseTranslate
    | BuildPhaseGatherInputs
    | BuildPhaseBuild
    | BuildPhaseFeeAlignment
    | BuildPhaseUnsupported
    deriving stock (Eq, Show)

-- | Extra structured context added while an error moves outward.
data BuildErrorContext
    = ContextIntentAction !Text
    | ContextBuildPhase !BuildFailurePhase
    | ContextWalletInput !Text
    | ContextReportDestination !FilePath
    | ContextNetwork !Text
    deriving stock (Eq, Show)

-- | Stable project-owned build diagnostic.
data BuildDiagnostic
    = DiagnosticScriptEvaluationFailed !Text !Text
    | DiagnosticInsufficientFee !Coin !Coin
    | DiagnosticFeeNotConverged
    | DiagnosticCollateralShortfall !Coin !Coin
    | DiagnosticChecksFailed !Text
    | DiagnosticBumpFeeFailed !Text
    | DiagnosticMissingUtxos ![Text]
    | DiagnosticFeeAlignmentFailed !Text
    | DiagnosticTranslateFailed !Text
    | DiagnosticUnsupportedAction !Text
    deriving stock (Eq, Show)

-- | Expected treasury build failure with stable rendering.
data TreasuryBuildError = TreasuryBuildError
    { tbeAction :: !TreasuryBuildAction
    , tbePhase :: !BuildFailurePhase
    , tbeContext :: ![BuildErrorContext]
    , tbeDiagnostic :: !BuildDiagnostic
    }
    deriving stock (Eq, Show)

-- | Compatibility exception for callers that still use throwing APIs.
newtype TreasuryBuildException
    = TreasuryBuildException TreasuryBuildError
    deriving stock (Show)

instance Exception TreasuryBuildException where
    displayException (TreasuryBuildException err) =
        T.unpack (renderTreasuryBuildError err)

data ActionBuildError = ActionBuildError
    { abePhase :: !BuildFailurePhase
    , abeContext :: ![BuildErrorContext]
    , abeDiagnostic :: !BuildDiagnostic
    }
    deriving stock (Eq, Show)

treasuryBuildError
    :: TreasuryBuildAction
    -> BuildFailurePhase
    -> BuildDiagnostic
    -> TreasuryBuildError
treasuryBuildError action phase diagnostic =
    TreasuryBuildError
        { tbeAction = action
        , tbePhase = phase
        , tbeContext = []
        , tbeDiagnostic = diagnostic
        }

actionBuildError
    :: BuildFailurePhase
    -> BuildDiagnostic
    -> ActionBuildError
actionBuildError phase diagnostic =
    ActionBuildError
        { abePhase = phase
        , abeContext = []
        , abeDiagnostic = diagnostic
        }

nestActionBuildError
    :: TreasuryBuildAction
    -> ActionBuildError
    -> TreasuryBuildError
nestActionBuildError action err =
    TreasuryBuildError
        { tbeAction = action
        , tbePhase = abePhase err
        , tbeContext = abeContext err
        , tbeDiagnostic = abeDiagnostic err
        }

withBuildErrorContext
    :: BuildErrorContext
    -> TreasuryBuildError
    -> TreasuryBuildError
withBuildErrorContext ctx err =
    err{tbeContext = ctx : tbeContext err}

mapTreasuryBuildExceptionContext
    :: BuildErrorContext
    -> TreasuryBuildException
    -> TreasuryBuildException
mapTreasuryBuildExceptionContext ctx (TreasuryBuildException err) =
    TreasuryBuildException (withBuildErrorContext ctx err)

withTreasuryBuildExceptionContext
    :: BuildErrorContext
    -> IO a
    -> IO a
withTreasuryBuildExceptionContext ctx action = do
    result <- try action
    case result of
        Left err ->
            throwIO (mapTreasuryBuildExceptionContext ctx err)
        Right ok -> pure ok

treasuryBuildErrorFromBuildError
    :: TreasuryBuildAction
    -> BuildFailurePhase
    -> BuildError ()
    -> TreasuryBuildError
treasuryBuildErrorFromBuildError action phase =
    treasuryBuildError action phase . diagnosticFromBuildError

diagnosticFromBuildError :: BuildError () -> BuildDiagnostic
diagnosticFromBuildError = \case
    EvalFailure purpose reason ->
        DiagnosticScriptEvaluationFailed
            (T.pack (show purpose))
            (T.pack reason)
    BalanceFailed balanceError ->
        diagnosticFromBalanceError balanceError
    ChecksFailed checks ->
        DiagnosticChecksFailed (T.pack (show checks))
    BumpFeeFailed reason ->
        DiagnosticBumpFeeFailed (T.pack reason)

diagnosticFromBalanceError :: BalanceError -> BuildDiagnostic
diagnosticFromBalanceError = \case
    InsufficientFee required available ->
        DiagnosticInsufficientFee required available
    FeeNotConverged ->
        DiagnosticFeeNotConverged
    CollateralShortfall required available ->
        DiagnosticCollateralShortfall required available

treasuryBuildErrorCode :: TreasuryBuildError -> Text
treasuryBuildErrorCode err =
    case tbeDiagnostic err of
        DiagnosticScriptEvaluationFailed{} ->
            "script-evaluation-failed"
        DiagnosticInsufficientFee{} ->
            "insufficient-fee-capacity"
        DiagnosticFeeNotConverged ->
            "fee-not-converged"
        DiagnosticCollateralShortfall{} ->
            "collateral-shortfall"
        DiagnosticChecksFailed{} ->
            "final-validation-failed"
        DiagnosticBumpFeeFailed{} ->
            "fee-bump-failed"
        DiagnosticMissingUtxos{} ->
            "missing-utxos"
        DiagnosticFeeAlignmentFailed{} ->
            "fee-alignment-failed"
        DiagnosticTranslateFailed{} ->
            "intent-translation-failed"
        DiagnosticUnsupportedAction{} ->
            "unsupported-action"

renderTreasuryBuildError :: TreasuryBuildError -> Text
renderTreasuryBuildError err =
    "tx-build: "
        <> renderAction (tbeAction err)
        <> " failed "
        <> renderPhase (tbePhase err)
        <> ": "
        <> renderDiagnostic (tbeDiagnostic err)
        <> renderContexts (tbeContext err)

renderAction :: TreasuryBuildAction -> Text
renderAction = \case
    BuildActionSwap -> "swap"
    BuildActionDisburse -> "disburse"
    BuildActionWithdraw -> "withdraw"
    BuildActionReorganize -> "reorganize"
    BuildActionIntent -> "intent"

renderPhase :: BuildFailurePhase -> Text
renderPhase = \case
    BuildPhaseTranslate -> "while translating the intent"
    BuildPhaseGatherInputs -> "while gathering inputs"
    BuildPhaseBuild -> "while building the transaction"
    BuildPhaseFeeAlignment -> "while aligning the final fee"
    BuildPhaseUnsupported -> "because the action is unsupported"

renderDiagnostic :: BuildDiagnostic -> Text
renderDiagnostic = \case
    DiagnosticScriptEvaluationFailed purpose reason ->
        "script evaluation failed for "
            <> purpose
            <> ": "
            <> reason
    DiagnosticInsufficientFee (Coin required) (Coin available) ->
        "insufficient fee capacity; required lovelace: "
            <> T.pack (show required)
            <> "; available lovelace: "
            <> T.pack (show available)
    DiagnosticFeeNotConverged ->
        "fee did not converge; retry with fresh chain state or report protocol-parameter drift"
    DiagnosticCollateralShortfall (Coin required) (Coin available) ->
        "collateral shortfall; required collateral lovelace: "
            <> T.pack (show required)
            <> "; available collateral lovelace: "
            <> T.pack (show available)
    DiagnosticChecksFailed checks ->
        "final validation checks failed: " <> checks
    DiagnosticBumpFeeFailed reason ->
        "fee bump failed: " <> reason
    DiagnosticMissingUtxos missing ->
        "missing required UTxOs from the chain context: "
            <> T.intercalate ", " missing
    DiagnosticFeeAlignmentFailed reason ->
        "fee alignment failed: " <> reason
    DiagnosticTranslateFailed reason ->
        "intent translation failed: " <> reason
    DiagnosticUnsupportedAction action ->
        action <> " is not implemented"

renderContexts :: [BuildErrorContext] -> Text
renderContexts [] = ""
renderContexts contexts =
    " (context: "
        <> T.intercalate "; " (renderContext <$> contexts)
        <> ")"

renderContext :: BuildErrorContext -> Text
renderContext = \case
    ContextIntentAction action ->
        "action=" <> action
    ContextBuildPhase phase ->
        "phase=" <> T.pack (show phase)
    ContextWalletInput input ->
        "wallet-input=" <> input
    ContextReportDestination path ->
        "report=" <> T.pack path
    ContextNetwork network ->
        "network=" <> network

throwTreasuryBuildException :: TreasuryBuildError -> IO a
throwTreasuryBuildException =
    throwIO . TreasuryBuildException

runActionBuild
    :: TreasuryBuildAction
    -> ExceptT ActionBuildError IO a
    -> IO a
runActionBuild action buildAction = do
    result <-
        runExceptT $
            withExceptT (nestActionBuildError action) buildAction
    either throwTreasuryBuildException pure result

missingUtxosError :: [TxIn] -> ActionBuildError
missingUtxosError missing =
    actionBuildError
        BuildPhaseGatherInputs
        (DiagnosticMissingUtxos (T.pack . show <$> missing))

-- ----------------------------------------------------
-- Driver
-- ----------------------------------------------------

{- | Action-polymorphic build entry. The type-family
makes @a@ pick the right translated record at each call
site. The case on @SAction a@ is the only place a
runtime selection appears; once inside a branch, the
type family pins down @Translated a@ and the runner is
fully type-safe.
-}
runBuild
    :: ChainContext
    -> TranslatedShared
    -> SAction a
    -> Translated a
    -> IO TreasuryBuildResult
runBuild ctx shared sa translated = do
    result <- runExceptT (runBuildExcept ctx shared sa translated)
    either throwTreasuryBuildException pure result

runBuildExcept
    :: ChainContext
    -> TranslatedShared
    -> SAction a
    -> Translated a
    -> ExceptT TreasuryBuildError IO TreasuryBuildResult
runBuildExcept ctx shared sa translated = case sa of
    SSwap ->
        withExceptT
            (nestActionBuildError BuildActionSwap)
            ( runSwapAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletTxIn shared)
                (tsWalletAddr shared)
            )
    SDisburse ->
        withExceptT
            (nestActionBuildError BuildActionDisburse)
            ( runDisburseAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletAddr shared)
            )
    SWithdraw ->
        withExceptT
            (nestActionBuildError BuildActionWithdraw)
            ( runWithdrawAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletAddr shared)
            )
    SReorganize ->
        throwE $
            treasuryBuildError
                BuildActionReorganize
                BuildPhaseUnsupported
                (DiagnosticUnsupportedAction "reorganize")

{- | Caller-friendly wrapper for the parser's existential
return type. Decodes-then-translates-then-builds.
-}
runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO TreasuryBuildResult
runFromIntent ctx some = do
    result <- runFromIntentEither ctx some
    either throwTreasuryBuildException pure result

runFromIntentEither
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO (Either TreasuryBuildError TreasuryBuildResult)
runFromIntentEither ctx (SomeTreasuryIntent sa intent) =
    runExceptT $ do
        case translateIntent sa intent of
            Left e ->
                throwE $
                    treasuryBuildError
                        BuildActionIntent
                        BuildPhaseTranslate
                        (DiagnosticTranslateFailed (T.pack e))
            Right (shared, translated) ->
                runBuildExcept ctx shared sa translated

-- ----------------------------------------------------
-- Withdraw runner
-- ----------------------------------------------------

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
    -> IO TreasuryBuildResult
runWithdraw ctx intent rationale walletAddr =
    runActionBuild BuildActionWithdraw $
        runWithdrawAction ctx intent rationale walletAddr

runWithdrawAction
    :: ChainContext
    -> WithdrawIntent
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO TreasuryBuildResult
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
                    (diagnosticFromBuildError (e :: BuildError ()))
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
                TreasuryBuildResult
                    { tbrCborBytes = cbor
                    , tbrFeeLovelace = feeLov
                    , tbrTotalCollateralLovelace =
                        totalColl
                    , tbrScriptResults = scriptResults
                    , tbrFinalTxBody = body
                    , tbrTxId = txIdText tx
                    , tbrWalletInputs = walletInputUtxos
                    , tbrTreasuryInputs = []
                    , tbrSundaeOrderOutputs = []
                    , tbrTreasuryLeftoverOutput = Nothing
                    , tbrPerChunkOverheadLovelace = Coin 0
                    , tbrWalletChangeOutput =
                        indexedOutputAt changeOutputIndex body
                    , tbrCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , tbrCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

-- ----------------------------------------------------
-- Disburse runner
-- ----------------------------------------------------

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
    -> IO TreasuryBuildResult
runDisburse ctx intent rationale walletAddr =
    runActionBuild BuildActionDisburse $
        runDisburseAction ctx intent rationale walletAddr

runDisburseAction
    :: ChainContext
    -> DisburseIntent
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO TreasuryBuildResult
runDisburseAction ctx intent rationale walletAddr = case intent of
    DisburseAdaIntent fields payload ->
        runDisburseAdaAction ctx fields payload rationale walletAddr

-- | The ADA-disburse build pipeline.
runDisburseAdaAction
    :: ChainContext
    -> DisburseIntentFields
    -> DisburseAdaPayload
    -> Metadatum
    -> Addr
    -> ExceptT ActionBuildError IO TreasuryBuildResult
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
                    (diagnosticFromBuildError (e :: BuildError ()))
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
                TreasuryBuildResult
                    { tbrCborBytes = cbor
                    , tbrFeeLovelace = feeLov
                    , tbrTotalCollateralLovelace =
                        totalColl
                    , tbrScriptResults = scriptResults
                    , tbrFinalTxBody = body
                    , tbrTxId = txIdText tx
                    , tbrWalletInputs = walletInputUtxos
                    , tbrTreasuryInputs = treasuryInputUtxos
                    , tbrSundaeOrderOutputs = []
                    , tbrTreasuryLeftoverOutput = Nothing
                    , tbrPerChunkOverheadLovelace = Coin 0
                    , tbrWalletChangeOutput =
                        indexedOutputAt 2 body
                    , tbrCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , tbrCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

{- | Match @cardano-cli transaction build@'s conservative
key-witness fee estimate for bash-derived golden oracles.

The upstream bash recipes do not pass
@--witness-override@, so @cardano-cli@ prices the unsigned
body with its default key-witness estimate. For the
current swap/disburse oracles this is seven witnesses,
not the single dummy witness used by
@cardano-node-clients@' generic balancer. Without this
adjustment the body shape and ex-units match the bash
artifact, but the fee, collateral total, collateral
return, and change output are all under the
cardano-cli output.
-}
alignCardanoCliBuildFee
    :: PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ resolved reference inputs, for Conway reference-script fee
    -> Int
    -- ^ change output index appended by the balancer
    -> ConwayTx
    -> Either String ConwayTx
alignCardanoCliBuildFee pp refUtxos changeIx =
    go (5 :: Int)
  where
    go 0 _ =
        Left "fee did not converge"
    go n tx =
        let body = tx ^. bodyTxL
            Withdrawals withdrawals =
                body ^. withdrawalsTxBodyL
            refBytes =
                refScriptsSize
                    (body ^. referenceInputsTxBodyL)
                    refUtxos
            witnessCount =
                1
                    + Set.size (body ^. inputsTxBodyL)
                    + Set.size (body ^. collateralInputsTxBodyL)
                    + Set.size
                        (body ^. reqSignerHashesTxBodyL)
                    + Map.size withdrawals
            target =
                estimateMinFeeTx pp tx witnessCount 0 refBytes
            current = body ^. feeTxBodyL
        in  if target <= current
                then Right tx
                else do
                    bumped <-
                        bumpBuildFee
                            pp
                            changeIx
                            current
                            target
                            tx
                    go (n - 1) bumped

bumpBuildFee
    :: PParams ConwayEra
    -> Int
    -> Coin
    -> Coin
    -> ConwayTx
    -> Either String ConwayTx
bumpBuildFee pp changeIx oldFee newFee tx = do
    let feeDelta = unCoin newFee - unCoin oldFee
    outputs' <-
        adjustOutputCoin
            changeIx
            feeDelta
            (tx ^. bodyTxL . outputsTxBodyL)
    bodyWithFee <-
        adjustCollateralFields
            pp
            newFee
            ( tx
                ^. bodyTxL
            )
    Right $
        tx
            & bodyTxL .~ bodyWithFee
            & bodyTxL . feeTxBodyL .~ newFee
            & bodyTxL . outputsTxBodyL .~ outputs'

adjustOutputCoin
    :: Int
    -> Integer
    -> StrictSeq.StrictSeq (TxOut ConwayEra)
    -> Either String (StrictSeq.StrictSeq (TxOut ConwayEra))
adjustOutputCoin ix delta outs =
    case splitAt ix (toList outs) of
        (_, []) ->
            Left "change output index out of range"
        (before, changeOut : after) ->
            let Coin current = changeOut ^. coinTxOutL
            in  if current < delta
                    then Left "change output cannot cover fee bump"
                    else
                        Right $
                            StrictSeq.fromList $
                                before
                                    ++ [ changeOut
                                            & coinTxOutL
                                                .~ Coin
                                                    ( current
                                                        - delta
                                                    )
                                       ]
                                    ++ after

adjustCollateralFields
    :: PParams ConwayEra
    -> Coin
    -> TxBody TopTx ConwayEra
    -> Either String (TxBody TopTx ConwayEra)
adjustCollateralFields pp newFee body =
    case body ^. totalCollateralTxBodyL of
        SNothing -> Right body
        SJust oldTotal ->
            let newTotal = collateralFor newFee
                delta =
                    unCoin newTotal
                        - unCoin oldTotal
            in  case body ^. collateralReturnTxBodyL of
                    SNothing ->
                        Right $
                            body
                                & totalCollateralTxBodyL
                                    .~ SJust newTotal
                    SJust retOut -> do
                        let Coin retCoin =
                                retOut ^. coinTxOutL
                        if retCoin < delta
                            then
                                Left
                                    "collateral return cannot cover fee bump"
                            else
                                Right $
                                    body
                                        & totalCollateralTxBodyL
                                            .~ SJust newTotal
                                        & collateralReturnTxBodyL
                                            .~ SJust
                                                ( retOut
                                                    & coinTxOutL
                                                        .~ Coin
                                                            ( retCoin
                                                                - delta
                                                            )
                                                )
  where
    collateralFor (Coin f) =
        let pct =
                fromIntegral
                    (pp ^. ppCollateralPercentageL)
            ceilDiv a b = (a + b - 1) `div` b
        in  Coin (ceilDiv (f * pct) 100)

-- ----------------------------------------------------
-- Swap runner
-- ----------------------------------------------------

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
    -> IO TreasuryBuildResult
runSwap ctx intent rationale walletInput walletAddr =
    runActionBuild BuildActionSwap $
        runSwapAction ctx intent rationale walletInput walletAddr

runSwapAction
    :: ChainContext
    -> SwapIntent
    -> Metadatum
    -> TxIn
    -> Addr
    -> ExceptT ActionBuildError IO TreasuryBuildResult
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
                    (diagnosticFromBuildError (e :: BuildError ()))
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
                TreasuryBuildResult
                    { tbrCborBytes = cbor
                    , tbrFeeLovelace = feeLov
                    , tbrTotalCollateralLovelace =
                        totalColl
                    , tbrScriptResults = scriptResults
                    , tbrFinalTxBody = body
                    , tbrTxId = txIdText tx
                    , tbrWalletInputs = walletInputUtxos
                    , tbrTreasuryInputs = treasuryInputUtxos
                    , tbrSundaeOrderOutputs =
                        indexedOutputs
                            0
                            (length (siSwapOrders intent))
                            body
                    , tbrTreasuryLeftoverOutput =
                        indexedOutputAt
                            (length (siSwapOrders intent))
                            body
                    , tbrPerChunkOverheadLovelace =
                        siSwapOrderExtraLovelace intent
                    , tbrWalletChangeOutput =
                        indexedOutputAt
                            (length (siSwapOrders intent) + 1)
                            body
                    , tbrCollateralInput =
                        collateralInputFrom body walletInputUtxos
                    , tbrCollateralReturn =
                        strictMaybe
                            (body ^. collateralReturnTxBodyL)
                    }

txIdText :: ConwayTx -> Text
txIdText tx =
    case txIdTx tx of
        TxId h ->
            Text.decodeUtf8 $
                B16.encode $
                    hashToBytes $
                        extractHash h

indexedOutputAt
    :: Int
    -> TxBody TopTx ConwayEra
    -> Maybe (Int, TxOut ConwayEra)
indexedOutputAt index body =
    (index,) <$> listToMaybe (drop index outputs)
  where
    outputs = toList (body ^. outputsTxBodyL)

indexedOutputs
    :: Int
    -> Int
    -> TxBody TopTx ConwayEra
    -> [(Int, TxOut ConwayEra)]
indexedOutputs start count body =
    take count . drop start . zip [0 ..] $
        toList (body ^. outputsTxBodyL)

collateralInputFrom
    :: TxBody TopTx ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
collateralInputFrom body =
    find
        ( \(txIn, _) ->
            Set.member txIn (body ^. collateralInputsTxBodyL)
        )

strictMaybe :: StrictMaybe a -> Maybe a
strictMaybe = \case
    SNothing -> Nothing
    SJust value -> Just value
