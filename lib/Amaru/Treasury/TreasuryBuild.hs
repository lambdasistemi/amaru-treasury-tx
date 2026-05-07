{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

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

In this phase-4 cut the swap and disburse branches are
wired. Withdraw and reorganize land with
[#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
and
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46).
-}
module Amaru.Treasury.TreasuryBuild
    ( -- * Outputs
      TreasuryBuildResult (..)
    , ScriptResult (..)

      -- * Drivers
    , runBuild
    , runFromIntent
    , runDisburse
    , runSwap
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (estimateMinFeeTx)
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
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Balance (refScriptsSize)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
    ( BuildError
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
    }

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
runBuild ctx shared sa translated = case sa of
    SSwap ->
        runSwap
            ctx
            translated
            (tsRationale shared)
            (tsWalletTxIn shared)
            (tsWalletAddr shared)
    SDisburse ->
        runDisburse
            ctx
            translated
            (tsRationale shared)
            (tsWalletAddr shared)
    SWithdraw ->
        throwIO . userError $
            "runBuild: 'withdraw' not yet shipped (#45)"
    SReorganize ->
        throwIO . userError $
            "runBuild: 'reorganize' not yet shipped (#46)"

{- | Caller-friendly wrapper for the parser's existential
return type. Decodes-then-translates-then-builds.
-}
runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO TreasuryBuildResult
runFromIntent ctx (SomeTreasuryIntent sa intent) = do
    case translateIntent sa intent of
        Left e ->
            throwIO . userError $
                "runFromIntent: translate: " <> e
        Right (shared, translated) ->
            runBuild ctx shared sa translated

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
runDisburse ctx intent rationale walletAddr = case intent of
    DisburseAdaIntent fields payload ->
        runDisburseAda ctx fields payload rationale walletAddr

-- | The ADA-disburse build pipeline.
runDisburseAda
    :: ChainContext
    -> DisburseIntentFields
    -> DisburseAdaPayload
    -> Metadatum
    -> Addr
    -> IO TreasuryBuildResult
runDisburseAda ctx fields payload rationale walletAddr = do
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
        throwIO . userError $
            "runDisburse: missing UTxOs in context: "
                <> show missing
    let inputUtxos =
            (walletInput, utxoMap Map.! walletInput)
                : [ (i, utxoMap Map.! i)
                  | i <- treasuryInputs
                  ]
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
                    (error "runDisburse: unexpected ctx")
    result <-
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
            throwIO . userError $
                "runDisburse: build failed: "
                    <> show (e :: BuildError ())
        Right tx0 -> do
            tx <- case alignCardanoCliDisburseFee pp refUtxos 2 tx0 of
                Left e ->
                    throwIO . userError $
                        "runDisburse: fee alignment failed: "
                            <> e
                Right ok -> pure ok
            let body = tx ^. bodyTxL
                feeLov = body ^. feeTxBodyL
                totalColl = case body
                    ^. totalCollateralTxBodyL of
                    SJust c -> c
                    SNothing -> Coin 0
            scriptMap <- ccEvaluateTx ctx tx
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
                    }

{- | Match @cardano-cli transaction build@'s conservative
key-witness fee estimate for the bash-derived disburse
oracle.

The upstream bash recipe does not pass
@--witness-override@, so @cardano-cli@ prices the unsigned
body with its default key-witness estimate. For the ADA
disburse oracle this is seven witnesses, not the single
dummy witness used by @cardano-node-clients@' generic
balancer. Without this adjustment the body shape and
ex-units match the bash artifact, but the fee,
collateral total, collateral return, and change output
are all under the cardano-cli output.
-}
alignCardanoCliDisburseFee
    :: PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ resolved reference inputs, for Conway reference-script fee
    -> Int
    -- ^ change output index appended by the balancer
    -> ConwayTx
    -> Either String ConwayTx
alignCardanoCliDisburseFee pp refUtxos changeIx =
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
                        bumpDisburseFee
                            pp
                            changeIx
                            current
                            target
                            tx
                    go (n - 1) bumped

bumpDisburseFee
    :: PParams ConwayEra
    -> Int
    -> Coin
    -> Coin
    -> ConwayTx
    -> Either String ConwayTx
bumpDisburseFee pp changeIx oldFee newFee tx = do
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
runSwap ctx intent rationale walletInput walletAddr = do
    let utxoMap = ccUtxos ctx
        required =
            walletInput
                : siTreasuryUtxos intent
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
        throwIO . userError $
            "runSwap: missing UTxOs in context: "
                <> show missing
    let inputUtxos =
            (walletInput, utxoMap Map.! walletInput)
                : [ (i, utxoMap Map.! i)
                  | i <- siTreasuryUtxos intent
                  ]
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
                    (error "runSwap: unexpected ctx")
    result <-
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
            throwIO . userError $
                "runSwap: build failed: "
                    <> show (e :: BuildError ())
        Right tx -> do
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
            scriptMap <- ccEvaluateTx ctx tx
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
                    }
