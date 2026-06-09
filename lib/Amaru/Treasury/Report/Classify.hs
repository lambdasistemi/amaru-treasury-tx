{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.Classify
    ( ProducedOutputRole (..)
    , classifyOutputRole
    , producedOutputRoleText
    ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Build
    ( BuildResult (..)
    )

data ProducedOutputRole
    = OutputSwapOrder
    | OutputBeneficiary
    | OutputTreasuryLeftover
    | OutputWalletChange
    | OutputCollateralReturn
    | OutputMetadata
    | OutputUnknown
    deriving stock (Eq, Show)

instance ToJSON ProducedOutputRole where
    toJSON =
        toJSON . producedOutputRoleText

instance FromJSON ProducedOutputRole where
    parseJSON = withText "ProducedOutputRole" $ \case
        "swapOrder" -> pure OutputSwapOrder
        "beneficiary" -> pure OutputBeneficiary
        "treasuryLeftover" -> pure OutputTreasuryLeftover
        "walletChange" -> pure OutputWalletChange
        "collateralReturn" -> pure OutputCollateralReturn
        "metadata" -> pure OutputMetadata
        "unknown" -> pure OutputUnknown
        other -> fail ("unknown produced-output role: " <> T.unpack other)

classifyOutputRole :: BuildResult -> Int -> ProducedOutputRole
classifyOutputRole result index
    | Set.member index swapOrderIndexes = OutputSwapOrder
    | Set.member index beneficiaryIndexes = OutputBeneficiary
    | Just index == (fst <$> brTreasuryLeftoverOutput result) =
        OutputTreasuryLeftover
    | Just index == (fst <$> brWalletChangeOutput result) =
        OutputWalletChange
    | otherwise = OutputUnknown
  where
    swapOrderIndexes =
        Set.fromList (fst <$> brSundaeOrderOutputs result)
    beneficiaryIndexes =
        Set.fromList (fst <$> brBeneficiaryOutputs result)

producedOutputRoleText :: ProducedOutputRole -> Text
producedOutputRoleText = \case
    OutputSwapOrder -> "swapOrder"
    OutputBeneficiary -> "beneficiary"
    OutputTreasuryLeftover -> "treasuryLeftover"
    OutputWalletChange -> "walletChange"
    OutputCollateralReturn -> "collateralReturn"
    OutputMetadata -> "metadata"
    OutputUnknown -> "unknown"
