{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Build.Result
Description : Result types returned by treasury transaction builds
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Result
    ( ScriptResult (..)
    , BuildResult (..)
    ) where

import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (TopTx, TxBody)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.TxIn (TxIn)

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
data BuildResult = BuildResult
    { brCborBytes :: !BSL.ByteString
    -- ^ raw Conway tx CBOR
    , brFeeLovelace :: !Coin
    -- ^ fee assigned by 'build'
    , brTotalCollateralLovelace :: !Coin
    -- ^ @total_collateral@ as recorded in the final
    --     body. 'Coin' 0 if the body has no
    --     @total_collateral@ field (a non-script tx).
    , brScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced tx
    , brFinalTxBody :: !(TxBody TopTx ConwayEra)
    -- ^ final balanced transaction body used to render
    --     deterministic reports without rebuilding
    , brTxId :: !Text
    -- ^ transaction id of the final balanced transaction
    , brWalletInputs :: ![(TxIn, TxOut ConwayEra)]
    -- ^ wallet-owned inputs used to fuel the build
    , brTreasuryInputs :: ![(TxIn, TxOut ConwayEra)]
    -- ^ treasury-owned inputs spent by the build
    , brSundaeOrderOutputs :: ![(Int, TxOut ConwayEra)]
    -- ^ final Sundae order outputs, paired with ledger output indexes
    , brTreasuryLeftoverOutput :: !(Maybe (Int, TxOut ConwayEra))
    -- ^ final treasury leftover output, when present
    , brPerChunkOverheadLovelace :: !Coin
    -- ^ per-order overhead funded by the treasury for swap builds
    , brWalletChangeOutput :: !(Maybe (Int, TxOut ConwayEra))
    -- ^ final wallet change output, paired with its output index
    , brCollateralInput :: !(Maybe (TxIn, TxOut ConwayEra))
    -- ^ wallet input selected as collateral, when present
    , brCollateralReturn :: !(Maybe (TxOut ConwayEra))
    -- ^ collateral-return output from the final body, when present
    , brResidualTreasuryInputs :: ![TxIn]
    -- ^ treasury inputs that were enumerated by the wizard but
    --     dropped by the reorganize batcher because the full set
    --     exceeded the per-tx exec-units / size ceiling. Empty when
    --     no truncation happened (the build used every wizard-listed
    --     input). The operator chains another reorganize on these
    --     after the first batch settles on-chain.
    --     See @Amaru.Treasury.Build.Reorganize.Batch@ for the math.
    }
