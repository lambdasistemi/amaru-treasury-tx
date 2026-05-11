{- |
Module      : Amaru.Treasury.Tx.DisburseBuild
Description : Live-build orchestration for disburse transactions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of the swap branch in
[`Amaru.Treasury.Build`](Amaru.Treasury.Build.html).
Threads a 'DisburseIntent' + rationale 'Metadatum'
through a 'ChainContext' and runs the full
[`Cardano.Node.Client.TxBuild.build`](https://github.com/lambdasistemi/cardano-node-clients)
loop.

This compatibility module handles the ADA disburse case
('DisburseAdaIntent'). The unified dispatcher in
'Amaru.Treasury.Build.runFromIntent' handles both ADA and
USDM disburse intents.

The final tx is re-evaluated against the script
evaluator so callers get a per-redeemer outcome
('dbrScriptResults') alongside the CBOR. Script
failures surface as @ScriptResult … (Left err)@; the
pipeline does not throw on script failure — the runner
in @Main.hs@ translates @Left@ into a non-zero exit
code per FR-011.
-}
module Amaru.Treasury.Tx.DisburseBuild
    ( -- * Inputs
      DisburseBuildInputs (..)

      -- * Outputs
    , DisburseBuildResult (..)
    , ScriptResult (..)

      -- * Driver
    , runDisburseBuild
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
    ( BuildError
    , InterpretIO (..)
    , build
    , setMetadata
    )
import Lens.Micro ((^.))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Build (ScriptResult (..))
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    , disburseAdaProgram
    )

-- | Everything 'runDisburseBuild' needs at runtime.
data DisburseBuildInputs = DisburseBuildInputs
    { dbiIntent :: !DisburseIntent
    -- ^ shape (treasury inputs, beneficiary, signers,
    --     validity bound, …)
    , dbiRationale :: !Metadatum
    -- ^ CIP-1694 rationale tree
    --     (see 'Amaru.Treasury.AuxData')
    , dbiWalletAddr :: !Addr
    -- ^ change address — also receives
    --     @collateral_return@ by default
    --     (see 'Amaru.Treasury.Build' header)
    }

{- | What 'runDisburseBuild' returns. Field set is identical
to 'Amaru.Treasury.Build.BuildResult'.
-}
data DisburseBuildResult = DisburseBuildResult
    { dbrCborBytes :: !BSL.ByteString
    -- ^ raw Conway tx CBOR
    , dbrFeeLovelace :: !Coin
    -- ^ fee assigned by 'build'
    , dbrTotalCollateralLovelace :: !Coin
    -- ^ @total_collateral@ as recorded in the final
    --     body. 'Coin' 0 if the body has no
    --     @total_collateral@ field (a non-script tx).
    , dbrScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced tx
    }

-- ----------------------------------------------------
-- Driver
-- ----------------------------------------------------

{- | Build a disburse transaction end-to-end against a
'ChainContext'. The context carries the only inputs the
build is allowed to read from "reality" (pparams,
UTxOs, script evaluator); supplying a frozen one
('Amaru.Treasury.ChainContext.frozenContext') makes the
build deterministic across chain drift.

USDM disburse intents are intentionally rejected here so
legacy direct callers do not accidentally use the pre-#52
compatibility path; call 'Amaru.Treasury.Build.runFromIntent'
for the unified dispatcher.
-}
runDisburseBuild
    :: ChainContext
    -> DisburseBuildInputs
    -> IO DisburseBuildResult
runDisburseBuild ctx dbi = case dbiIntent dbi of
    DisburseAdaIntent fields payload ->
        runAda ctx dbi fields payload
    DisburseUsdmIntent{} ->
        throwIO . userError $
            "runDisburseBuild: USDM disburse requires "
                <> "Amaru.Treasury.Build.runFromIntent"

-- | The ADA-disburse build pipeline.
runAda
    :: ChainContext
    -> DisburseBuildInputs
    -> DisburseIntentFields
    -> DisburseAdaPayload
    -> IO DisburseBuildResult
runAda ctx dbi fields payload = do
    let walletInput = difWalletUtxo fields
        walletAddr = dbiWalletAddr dbi
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
            "runDisburseBuild: missing UTxOs in context: "
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
            setMetadata label1694 (dbiRationale dbi)
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    ( error
                        "runDisburseBuild: unexpected ctx"
                    )
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
                "runDisburseBuild: build failed: "
                    <> show (e :: BuildError ())
        Right tx -> do
            let body = tx ^. bodyTxL
                feeLov = body ^. feeTxBodyL
                totalColl = case body
                    ^. totalCollateralTxBodyL of
                    SJust c -> c
                    SNothing -> Coin 0
            -- Re-evaluate on the final tx so callers see
            -- the per-redeemer outcome alongside the CBOR.
            -- The closure passed to 'build' above drove the
            -- balancing fixpoint; this second call captures
            -- script results once the body is settled.
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
                DisburseBuildResult
                    { dbrCborBytes = cbor
                    , dbrFeeLovelace = feeLov
                    , dbrTotalCollateralLovelace = totalColl
                    , dbrScriptResults = scriptResults
                    }
