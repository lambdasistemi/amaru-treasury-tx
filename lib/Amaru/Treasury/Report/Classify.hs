{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.Classify
    ( ProducedOutputRole (..)
    , classifyOutputRole
    , producedOutputRoleText
    ) where

import Data.Aeson (ToJSON (..))
import Data.Set qualified as Set
import Data.Text (Text)

import Amaru.Treasury.TreasuryBuild
    ( TreasuryBuildResult (..)
    )

data ProducedOutputRole
    = OutputSwapOrder
    | OutputTreasuryLeftover
    | OutputWalletChange
    | OutputCollateralReturn
    | OutputMetadata
    | OutputUnknown
    deriving stock (Eq, Show)

instance ToJSON ProducedOutputRole where
    toJSON =
        toJSON . producedOutputRoleText

classifyOutputRole :: TreasuryBuildResult -> Int -> ProducedOutputRole
classifyOutputRole result index
    | Set.member index swapOrderIndexes = OutputSwapOrder
    | Just index == (fst <$> tbrTreasuryLeftoverOutput result) =
        OutputTreasuryLeftover
    | Just index == (fst <$> tbrWalletChangeOutput result) =
        OutputWalletChange
    | otherwise = OutputUnknown
  where
    swapOrderIndexes =
        Set.fromList (fst <$> tbrSundaeOrderOutputs result)

producedOutputRoleText :: ProducedOutputRole -> Text
producedOutputRoleText = \case
    OutputSwapOrder -> "swapOrder"
    OutputTreasuryLeftover -> "treasuryLeftover"
    OutputWalletChange -> "walletChange"
    OutputCollateralReturn -> "collateralReturn"
    OutputMetadata -> "metadata"
    OutputUnknown -> "unknown"
