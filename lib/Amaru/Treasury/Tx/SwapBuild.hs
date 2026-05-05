{- |
Module      : Amaru.Treasury.Tx.SwapBuild
Description : Live-build orchestration for swap transactions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Threads a 'SwapIntent' + rationale 'Metadatum' through a
'Provider' (typically 'Amaru.Treasury.Backend.N2C'),
runs the full
[`Cardano.Node.Client.TxBuild.build`](https://github.com/lambdasistemi/cardano-node-clients)
loop with the live script evaluator, post-patches the
two CIP-40 collateral fields that
@cardano-node-clients@'s @build@ does not yet model
(see [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124)),
and re-evaluates the final tx so callers can be sure
every redeemer succeeds with the committed ExUnits.
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
import Data.Word (Word64)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
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
import Lens.Micro ((&), (.~), (^.))

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
    -- ^ change address (and collateral_return target)
    , sbiCollateralPercent :: !Word64
    -- ^ Conway default = 150
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
    -- ^ post-patched @total_collateral@
    , sbrScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced + collateral-patched tx
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
            let walletValue = case lookup walletInput inputUtxos of
                    Just txout ->
                        let MaryValue c _ =
                                txout ^. valueTxOutL
                        in  c
                    Nothing ->
                        error
                            "runSwapBuild: missing wallet"
                Coin feeLov = tx ^. bodyTxL . feeTxBodyL
                Coin walletLov = walletValue
                pct = sbiCollateralPercent sbi
                totalColl =
                    Coin
                        ( ( feeLov
                                * fromIntegral pct
                                + 99
                          )
                            `div` 100
                        )
                Coin totalCollLov = totalColl
                returnColl =
                    mkBasicTxOut
                        walletAddr
                        ( MaryValue
                            (Coin (walletLov - totalCollLov))
                            (MultiAsset Map.empty)
                        )
                txPatched =
                    tx
                        & bodyTxL
                            . totalCollateralTxBodyL
                            .~ SJust totalColl
                        & bodyTxL
                            . collateralReturnTxBodyL
                            .~ SJust returnColl
            scriptMap <- ccEvaluateTx ctx txPatched
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
                        (txPatched :: ConwayTx)
            pure
                SwapBuildResult
                    { sbrCborBytes = cbor
                    , sbrFeeLovelace = Coin feeLov
                    , sbrTotalCollateralLovelace =
                        totalColl
                    , sbrScriptResults = scriptResults
                    }
