{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.SwapRerate
Description : CLI parser and branch helpers for swap-rerate
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @swap-rerate@ command surface selects pending SundaeSwap orders for
one treasury scope and records the new ADA/USDM rate. Slice 1 stops at
the parser and pure branch-decision layer; later slices resolve orders
and build unsigned transaction artifacts.
-}
module Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateOpts (..)
    , SwapRerateSelectionMode (..)
    , SwapRerateOrderCandidate (..)
    , SwapReratePassthroughReason (..)
    , SwapRerateDecision (..)
    , swapRerateOptsP
    , decideSwapRerateBranch
    , runSwapRerate
    ) where

import Control.Applicative
    ( some
    , (<|>)
    )
import Data.Char (toLower)
import Data.Foldable (traverse_)
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , flag'
    , help
    , long
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import System.Exit qualified as Exit

import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Swap.Rerate.Types
    ( RerateBudgetEstimate
    , ReratePlan (..)
    , ReratePlanReason
    , RerateSplit
    )

-- | Flags for the @swap-rerate@ subcommand.
data SwapRerateOpts = SwapRerateOpts
    { sroMetadataPath :: !FilePath
    -- ^ Path to local @journal/2026/metadata.json@.
    , sroScope :: !ScopeId
    -- ^ Treasury scope whose pending orders may be re-rated.
    , sroWalletTxIn :: !Text
    -- ^ Wallet fuel input.
    , sroCollateralTxIn :: !(Maybe Text)
    -- ^ Optional collateral input; later slices may default to the
    -- wallet input.
    , sroSelectionMode :: !SwapRerateSelectionMode
    -- ^ Operator selection mode for pending order retraction.
    , sroNewRate :: !Double
    -- ^ New ADA/USDM rate.
    , sroValidityHours :: !(Maybe Word16)
    -- ^ Optional validity horizon in hours.
    , sroOutPath :: !(Maybe FilePath)
    -- ^ Where to write unsigned CBOR hex; 'Nothing' means stdout.
    , sroReportPath :: !(Maybe FilePath)
    -- ^ Where to write the re-rate report JSON.
    , sroLog :: !(Maybe FilePath)
    -- ^ Where to write step logs; 'Nothing' means stderr.
    }
    deriving stock (Eq, Show)

-- | Operator choice for pending-order retraction.
data SwapRerateSelectionMode
    = -- | Retract exactly these order TxIns.
      SwapRerateSelectExplicit ![Text]
    | -- | Retract every pending order that belongs to the selected scope.
      SwapRerateSelectAll
    | -- | Continue through the plain swap path without retraction.
      SwapRerateDeclineRetract
    deriving stock (Eq, Show)

-- | Minimal pending-order fact used by the CLI branch helper.
data SwapRerateOrderCandidate = SwapRerateOrderCandidate
    { srocTxIn :: !Text
    -- ^ Pending order identifier rendered as @TXHASH#IX@.
    , srocScope :: !ScopeId
    -- ^ Scope attributed to the pending order.
    }
    deriving stock (Eq, Show)

-- | Why @swap-rerate@ should continue as a plain swap.
data SwapReratePassthroughReason
    = -- | The operator explicitly selected @--no-retract@.
      SwapRerateRetractDeclined
    | -- | No pending order is available for the selected scope.
      SwapRerateNoPendingOrders
    | -- | Selection was empty after CLI-level resolution.
      SwapRerateNoOrdersSelected
    deriving stock (Eq, Show)

-- | Branch decision reported by the CLI layer before transaction build.
data SwapRerateDecision
    = -- | The selected orders fit in one transaction.
      SwapRerateSingleTx
        !ReratePlanReason
        !RerateBudgetEstimate
        ![Text]
    | -- | The selected orders need the split fallback plan.
      SwapRerateSplitPlan
        !ReratePlanReason
        !RerateBudgetEstimate
        ![RerateSplit Text]
    | -- | No re-rate transaction should be built by this command path.
      SwapReratePassthrough !SwapReratePassthroughReason
    deriving stock (Eq, Show)

-- | Parse @swap-rerate@ options.
swapRerateOptsP :: Parser SwapRerateOpts
swapRerateOptsP =
    SwapRerateOpts
        <$> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> strOption
            ( long "wallet-txin"
                <> metavar "TXHASH#IX"
                <> help "Wallet fuel input"
            )
        <*> optional
            ( strOption
                ( long "collateral-txin"
                    <> metavar "TXHASH#IX"
                    <> help "Optional collateral input"
                )
            )
        <*> selectionModeP
        <*> option
            auto
            ( long "new-rate"
                <> metavar "ADA_USDM"
                <> help "New ADA/USDM rate for replacement orders"
            )
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "HOURS"
                    <> help
                        "Optional. Omit to use the chain's current horizon."
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write unsigned CBOR hex here (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "report"
                    <> metavar "PATH"
                    <> help "Write re-rate report JSON; '-' means stdout"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help "Where to write step lines (defaults to stderr)"
                )
            )

selectionModeP :: Parser SwapRerateSelectionMode
selectionModeP =
    noRetractP <|> allOrdersP <|> explicitOrdersP
  where
    noRetractP =
        flag'
            SwapRerateDeclineRetract
            ( long "no-retract"
                <> help
                    "Decline pending-order retraction and use the plain swap path"
            )
    allOrdersP =
        flag'
            SwapRerateSelectAll
            ( long "all-orders"
                <> help "Select every pending order for the requested scope"
            )
    explicitOrdersP =
        SwapRerateSelectExplicit
            <$> some
                ( strOption
                    ( long "order-txin"
                        <> metavar "TXHASH#IX"
                        <> help
                            "Pending SundaeSwap order UTxO to re-rate; repeat to select more than one"
                    )
                )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

{- | Decide whether the CLI should build one re-rate transaction, report
a split fallback, or continue through the plain swap path.

This helper intentionally works with rendered order TxIns so parser and
selection behavior can be tested before later slices resolve full ledger
UTxOs.
-}
decideSwapRerateBranch
    :: ScopeId
    -- ^ Requested scope.
    -> SwapRerateSelectionMode
    -- ^ Operator selection mode.
    -> [SwapRerateOrderCandidate]
    -- ^ Pending orders visible to the CLI layer.
    -> Maybe (ReratePlan Text)
    -- ^ Budget decision for the selected orders.
    -> Either Text SwapRerateDecision
decideSwapRerateBranch scope mode candidates plan =
    case mode of
        SwapRerateDeclineRetract ->
            Right $
                SwapReratePassthrough SwapRerateRetractDeclined
        _
            | null candidates ->
                Right $
                    SwapReratePassthrough SwapRerateNoPendingOrders
        SwapRerateSelectExplicit selected ->
            selectedDecision scope selected candidates plan
        SwapRerateSelectAll ->
            let selected =
                    filter
                        ((== scope) . srocScope)
                        candidates
            in  if null selected
                    then
                        Right $
                            SwapReratePassthrough
                                SwapRerateNoPendingOrders
                    else decisionFromPlan plan

selectedDecision
    :: ScopeId
    -> [Text]
    -> [SwapRerateOrderCandidate]
    -> Maybe (ReratePlan Text)
    -> Either Text SwapRerateDecision
selectedDecision scope selected candidates plan
    | null selected =
        Right $
            SwapReratePassthrough SwapRerateNoOrdersSelected
    | otherwise = do
        resolved <- traverse (resolveSelected candidates) selected
        traverse_ (ensureCandidateScope scope) resolved
        decisionFromPlan plan

resolveSelected
    :: [SwapRerateOrderCandidate]
    -> Text
    -> Either Text SwapRerateOrderCandidate
resolveSelected candidates txIn =
    case List.find ((== txIn) . srocTxIn) candidates of
        Just candidate -> Right candidate
        Nothing ->
            Left ("selected order " <> txIn <> " is not pending")

ensureCandidateScope
    :: ScopeId -> SwapRerateOrderCandidate -> Either Text ()
ensureCandidateScope expected SwapRerateOrderCandidate{..}
    | srocScope == expected = Right ()
    | otherwise =
        Left $
            "selected order "
                <> srocTxIn
                <> " belongs to "
                <> scopeText srocScope
                <> "; expected "
                <> scopeText expected

decisionFromPlan
    :: Maybe (ReratePlan Text) -> Either Text SwapRerateDecision
decisionFromPlan = \case
    Nothing ->
        Left "re-rate plan is required when orders are selected"
    Just (SingleTx reason estimate orders) ->
        Right (SwapRerateSingleTx reason estimate orders)
    Just (Split reason estimate groups) ->
        Right (SwapRerateSplitPlan reason estimate groups)

-- | Run @swap-rerate@.
runSwapRerate :: GlobalOpts -> SwapRerateOpts -> IO ()
runSwapRerate _ _ =
    Exit.die "swap-rerate: not implemented in slice 1"
