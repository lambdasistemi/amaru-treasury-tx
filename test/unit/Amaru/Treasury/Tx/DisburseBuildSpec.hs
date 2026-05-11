{- |
Module      : Amaru.Treasury.Tx.DisburseBuildSpec
Description : Unit tests for the unified disburse build branch
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.DisburseBuildSpec (spec) where

import Control.Exception
    ( SomeException
    , displayException
    )
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldThrow
    )

import Cardano.Ledger.Api.PParams (emptyPParams)

import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntentFile
    )
import Amaru.Treasury.TreasuryBuild (runFromIntent)

spec :: Spec
spec =
    describe "Amaru.Treasury.TreasuryBuild.runDisburse" $
        it "reports missing required UTxOs before balancing" $ do
            some <-
                expectRight
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/disburse/ada/intent.json"
            let ctx =
                    ChainContext
                        { ccPParams = emptyPParams
                        , ccUtxos = Map.empty
                        , ccEvaluateTx =
                            const (pure Map.empty)
                        }
            runFromIntent ctx some
                `shouldThrow` missingDisburseUtxos

missingDisburseUtxos :: SomeException -> Bool
missingDisburseUtxos =
    isInfixOf "tx-build: disburse failed while gathering inputs"
        . displayException

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure
