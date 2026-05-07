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

In this phase-4 cut only the swap branch is wired; the
others are 'throwIO' stubs. Disburse comes online when
[#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)
rebases on top of this PR's merge commit (tracked under
[#55](https://github.com/lambdasistemi/amaru-treasury-tx/issues/55)).
Withdraw and reorganize land with
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
    , runSwap
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
    ( BuildError
    , InterpretIO (..)
    , build
    , setMetadata
    )
import Lens.Micro ((^.))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , Translated
    , TranslatedShared (..)
    , translateIntent
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
        throwIO . userError $
            "runBuild: 'disburse' lands when feature 004 PR #47"
                <> " rebases on top of this commit (tracked"
                <> " under #55)"
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
