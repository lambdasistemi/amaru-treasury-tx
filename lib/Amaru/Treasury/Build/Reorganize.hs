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
import Cardano.Ledger.Coin (Coin (..), unCoin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build
    ( InterpretIO (..)
    , build
    , setMetadata
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString.Lazy qualified as BSL
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
import Amaru.Treasury.Build.Reorganize.Batch
    ( BatchLimits (..)
    , estimateNStar
    , measurementFits
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
import Cardano.Ledger.Api.PParams
    ( ppMaxTxExUnitsL
    , ppMaxTxSizeL
    )
import Cardano.Ledger.Plutus (ExUnits (..))
import Data.List (foldl', sortOn)
import Data.Ord (Down (..))
import Data.Word (Word32)

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

{- | Low-level action runner used by direct tests and the
dispatcher.

When the wizard-emitted intent enumerates more treasury UTxOs than
fit a single tx's @maxTxExUnits@ ceiling, this runner picks the
largest fitting subset via @Build.Reorganize.Batch@ (closed-form
sqrt projection as a first guess, then linear step-down by 1 on real
measurements until the cliff is found), rebuilds with the truncated
set, and surfaces the dropped outrefs as
@brResidualTreasuryInputs@. The operator chains another reorganize
on the residue after this batch settles on-chain.
-}
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
            , rgiScopesDeployedAt intent
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
    let pp = ccPParams ctx
        refUtxos =
            [ (i, utxoMap Map.! i)
            | i <- refInputs
            ]
        -- Order treasury inputs largest-value first so when we
        -- truncate we keep the highest-yield consolidation set.
        sortedTreasury =
            sortOn
                (Down . unCoin . inputLovelace . snd)
                treasuryInputUtxos
        sortedTreasuryTxIns = map fst sortedTreasury

        limits =
            BatchLimits
                { blMaxExUnits = pp ^. ppMaxTxExUnitsL
                , blMaxSize =
                    fromIntegral
                        (pp ^. ppMaxTxSizeL :: Word32)
                }

    -- Projected linear descent: one closed-form jump, then
    -- step-down by 1 against real measurements.
    (tx, selectedSubset) <-
        pickBatch
            ctx
            intent
            rationale
            walletAddr
            walletInputUtxos
            refUtxos
            limits
            False
            -- \^ haven't taken the math jump yet
            maxBatchIterations
            sortedTreasury

    -- Final validation on the chosen tx.
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
        residue =
            drop (length selectedSubset) sortedTreasuryTxIns
        changeOutputIndex = 1
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
            , brTreasuryInputs = selectedSubset
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
            , brResidualTreasuryInputs = residue
            }

{- | Maximum number of sample-fit-solve iterations.
One math jump + four linear step-downs = up to five rebuilds.
-}
maxBatchIterations :: Int
maxBatchIterations = 5

{- | Projected linear descent: one closed-form jump, then step
down by 1 until the measurement fits.

Builds with the given treasury subset and measures its real exec
units. If the measurement fits the per-tx ledger ceiling, returns
that batch.

If it doesn't fit, the runner takes one **closed-form jump** (the
sqrt projection @N* = floor(currentN · sqrt(limit / measured))@
from 'estimateNStar', with no safety alpha) to land near the true
cliff, then walks **down by 1** on subsequent iterations until the
measurement fits or the iteration budget runs out. The projection
is only trusted for the initial big leap; every subsequent value
of @N@ is confirmed by an actual rebuild measurement against the
live limits.

This is not Newton-Raphson (no derivatives are involved); it's a
projected linear descent — closed-form bracket from above, then
monotone step-down to the empirical cliff.

@haveJumped@ tracks whether the projection jump has already
happened; once it has, further mismatches step linearly to avoid
oscillating.
-}
pickBatch
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ wallet input UTxOs (always one entry on reorganize)
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ reference input UTxOs
    -> BatchLimits
    -> Bool
    -- ^ have we already taken the math jump?
    -> Int
    -- ^ iterations remaining
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ candidate treasury subset, largest-value first
    -> ExceptT ActionBuildError IO (ConwayTx, [(TxIn, TxOut ConwayEra)])
pickBatch ctx intent rationale walletAddr walletInputUtxos refUtxos limits haveJumped iters subset
    | iters <= 0 =
        throwE $
            actionBuildError
                BuildPhaseBuild
                ( DiagnosticChecksFailed $
                    T.pack "reorganize: batch math failed to converge within "
                        <> T.pack (show maxBatchIterations)
                        <> T.pack
                            " iterations; re-run wizard against a \
                            \smaller scope or narrower funding"
                )
    | length subset < 2 =
        throwE $
            actionBuildError
                BuildPhaseGatherInputs
                ( DiagnosticChecksFailed $
                    T.pack
                        "reorganize requires at least 2 treasury \
                        \UTxOs; batcher would have dropped below \
                        \that floor"
                )
    | otherwise = do
        let truncatedIntent =
                intent
                    { rgiTreasuryUtxos =
                        case subset of
                            ((i0, _) : rest) ->
                                i0 NE.:| map fst rest
                            [] ->
                                error
                                    "pickBatch: unreachable empty subset"
                    }
        (tx, total, sz) <-
            buildOnce
                ctx
                truncatedIntent
                rationale
                walletAddr
                walletInputUtxos
                refUtxos
                subset
        if measurementFits total sz limits
            then pure (tx, subset)
            else do
                let nNext
                        | not haveJumped =
                            estimateNStar
                                (length subset)
                                total
                                sz
                                limits
                        | otherwise = length subset - 1
                    nClamped =
                        min (length subset - 1) (max 2 nNext)
                pickBatch
                    ctx
                    intent
                    rationale
                    walletAddr
                    walletInputUtxos
                    refUtxos
                    limits
                    True
                    (iters - 1)
                    (take nClamped subset)

{- | One full build + align + measure pass against a specific
treasury subset.

Returns @(tx, totalExUnits, cborSize)@. The caller uses the metrics
to decide whether to keep or truncate, and runs 'validateFinalPhase1'
on the final accepted tx separately.
-}
buildOnce
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ wallet input UTxOs
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ reference input UTxOs
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ treasury subset to spend
    -> ExceptT ActionBuildError IO (ConwayTx, ExUnits, Int)
buildOnce ctx intent rationale walletAddr walletInputUtxos refUtxos subset = do
    let pp = ccPParams ctx
        inputUtxos = walletInputUtxos ++ subset
        preservedValue = preservedTreasuryValue subset
        evaluator tx = do
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
        changeOutputIndex = 1
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
    tx0 <-
        case result of
            Left e ->
                throwE $
                    actionBuildError
                        BuildPhaseBuild
                        (diagnosticFromTxBuildError (e :: TxBuild.BuildError ()))
            Right ok -> pure ok
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
    scriptMap <- liftIO $ ccEvaluateTx ctx tx
    let totalExUnits =
            foldl'
                addExUnits
                (ExUnits 0 0)
                [ ex
                | (_, Right ex) <- Map.toList scriptMap
                ]
        sz =
            fromIntegral $
                BSL.length $
                    serialize
                        (eraProtVerLow @ConwayEra)
                        (tx :: ConwayTx)
    pure (tx, totalExUnits, sz)

-- | Add two 'ExUnits' element-wise.
addExUnits :: ExUnits -> ExUnits -> ExUnits
addExUnits (ExUnits m1 s1) (ExUnits m2 s2) =
    ExUnits (m1 + m2) (s1 + s2)

-- | Lovelace amount carried by a 'TxOut'.
inputLovelace :: TxOut ConwayEra -> Coin
inputLovelace txout =
    case txout ^. valueTxOutL of
        MaryValue c _ -> c

preservedTreasuryValue
    :: [(a, TxOut ConwayEra)]
    -> MaryValue
preservedTreasuryValue =
    foldMap ((^. valueTxOutL) . snd)

allTreasuryInputsAtAddress
    :: ReorganizeIntent -> [(a, TxOut ConwayEra)] -> Bool
allTreasuryInputsAtAddress intent =
    all ((== rgiTreasuryAddress intent) . (^. addrTxOutL) . snd)
