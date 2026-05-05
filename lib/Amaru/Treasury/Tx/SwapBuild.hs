{- |
Module      : Amaru.Treasury.Tx.SwapBuild
Description : Live-build orchestration for swap transactions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Threads a 'SwapIntent' + rationale 'Metadatum' through a
'Provider' (typically 'Amaru.Treasury.Backend.N2C') and
runs the full
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
('sbrScriptResults') alongside the CBOR.
-}
module Amaru.Treasury.Tx.SwapBuild
    ( -- * Inputs
      SwapBuildInputs (..)

      -- * Outputs
    , SwapBuildResult (..)
    , ScriptResult (..)

      -- * Driver
    , runSwapBuild
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
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , swapProgram
    )

-- | Everything 'runSwapBuild' needs at runtime.
data SwapBuildInputs = SwapBuildInputs
    { sbiIntent :: !SwapIntent
    -- ^ swap shape (chunks, treasury UTxOs, signers, …)
    , sbiRationale :: !Metadatum
    -- ^ CIP-1694 rationale tree (see 'Amaru.Treasury.AuxData')
    , sbiWalletTxIn :: !TxIn
    -- ^ the wallet UTxO used as fuel + collateral
    , sbiWalletAddr :: !Addr
    -- ^ change address — also receives @collateral_return@
    --     by default (see module header)
    }

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

-- | What 'runSwapBuild' returns.
data SwapBuildResult = SwapBuildResult
    { sbrCborBytes :: !BSL.ByteString
    -- ^ raw Conway tx CBOR
    , sbrFeeLovelace :: !Coin
    -- ^ fee assigned by 'build'
    , sbrTotalCollateralLovelace :: !Coin
    -- ^ @total_collateral@ as recorded in the final
    --     body. 'Coin' 0 if the body has no
    --     @total_collateral@ field (a non-script tx).
    , sbrScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced tx
    }

-- ----------------------------------------------------
-- Driver
-- ----------------------------------------------------

{- | Build a swap transaction end-to-end against a
'ChainContext'. The context carries the only inputs the
build is allowed to read from "reality" (pparams,
UTxOs, script evaluator); supplying a frozen one
('Amaru.Treasury.ChainContext.frozenContext') makes the
build deterministic across chain drift.
-}
runSwapBuild
    :: ChainContext
    -> SwapBuildInputs
    -> IO SwapBuildResult
runSwapBuild ctx sbi = do
    let intent = sbiIntent sbi
        walletInput = sbiWalletTxIn sbi
        walletAddr = sbiWalletAddr sbi
        utxoMap = ccUtxos ctx
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
            "runSwapBuild: missing UTxOs in context: "
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
            setMetadata label1694 (sbiRationale sbi)
        noCtxIO :: InterpretIO q
        noCtxIO =
            InterpretIO $
                const
                    ( error
                        "runSwapBuild: unexpected ctx"
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
                "runSwapBuild: build failed: "
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
                SwapBuildResult
                    { sbrCborBytes = cbor
                    , sbrFeeLovelace = feeLov
                    , sbrTotalCollateralLovelace =
                        totalColl
                    , sbrScriptResults = scriptResults
                    }
