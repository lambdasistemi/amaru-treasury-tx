{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.SwapWizard
Description : CLI parser and runner for swap-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapWizard
    ( WizardOpts (..)
    , wizardOptsP
    , validateWizardInputControl
    , ChunkSpec (..)
    , WizardOrder (..)
    , WizardRate (..)
    , WizardRateParameters (..)
    , WizardSwapParameters (..)
    , rateToFraction
    , swapQuoteRequestChunk
    , usdmToLovelace
    ) where

import Control.Applicative ((<|>))
import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , flag'
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (ExitCode (..), exitWith)

import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.Cli.SwapCommon
    ( abortTr
    , providerToResolverEnv
    , traceEnv
    , traceRegistryView
    , traceResolverEnv
    )
import Amaru.Treasury.Cli.SwapOptions
    ( slippageReader
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , encodeSomeTreasuryIntent
    , tiPayload
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.SwapQuote
    ( SlippageBps
    )
import Amaru.Treasury.Tx.SwapQuote qualified as SQ
import Amaru.Treasury.Tx.SwapWizard
    ( AllAdaPlan (..)
    , InputControlOutcome (..)
    , RationaleAnswers (..)
    , ResolverAllAdaInput (..)
    , ResolverError (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WizardError
    , registryViewFromVerified
    , renderExclusionLogLine
    , renderWalletShortfall
    , renderWalletShortfallWithExcludes
    , resolveWizardEnvAllAdaIC
    , resolveWizardEnvIC
    , wizardToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace (WizardEvent (..))
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , InputControlError
    , OutRef
    , excludeUtxoP
    , extraTxInP
    , outRefText
    , renderInputControlError
    , validateInputControl
    )

data ChunkSpec
    = SplitCount !Int
    | ChunkUsdm !Double

data WizardOrder
    = FixedUsdm !Double !ChunkSpec
    | AllAda !Int

data WizardRate
    = WizardMinRate !Double
    | -- | Operator-supplied ADA/USDM quote with an explicit slippage policy.
      --   The wizard derives @minRate = quote × (1 - bps/10000)@ before
      --   building the intent; no outbound HTTP.
      WizardOverrideRate !Double !SlippageBps

data WizardSwapParameters = WizardSwapParameters
    { wspAmountLovelace :: !Integer
    , wspChunkSizeLovelace :: !Integer
    , wspRateNumerator :: !Integer
    , wspRateDenominator :: !Integer
    }
    deriving (Eq, Show)

data WizardRateParameters = WizardRateParameters
    { wrpRateNumerator :: !Integer
    , wrpRateDenominator :: !Integer
    }
    deriving (Eq, Show)

{- | Flags for the @swap-wizard@ subcommand.
Mirrors @specs/002-swap-wizard/contracts/swap-wizard-cli.md §1@.
-}
data WizardOpts = WizardOpts
    { wOptsWalletAddr :: !Text
    , wOptsMetadataPath :: !FilePath
    , wOptsOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , wOptsLog :: !(Maybe FilePath)
    -- ^ where to send 'WizardEvent' lines. 'Nothing' = stderr.
    , wOptsScope :: !ScopeId
    , wOptsOrder :: !WizardOrder
    -- ^ fixed-USDM target or all-ADA max-spend target.
    , wOptsRate :: !WizardRate
    -- ^ minimum acceptable USDM per ADA, either explicit or quote-derived
    , wOptsValidityHours :: !(Maybe Word16)
    , wOptsDescription :: !Text
    , wOptsJustification :: !Text
    , wOptsDestinationLabel :: !Text
    , wOptsEvent :: !(Maybe Text)
    , wOptsLabel :: !(Maybe Text)
    , wOptsSigners :: ![Text]
    , wOptsExcludeSet :: !ExclusionSet
    -- ^ Operator-supplied @--exclude-utxo@ refs, in flag
    -- order (#184).
    , wOptsForcedSet :: !ForcedInclusionSet
    -- ^ Operator-supplied @--extra-tx-in@ refs, in flag
    -- order (#184).
    }

wizardOptsP :: Parser WizardOpts
wizardOptsP =
    WizardOpts
        <$> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Wallet address (fuel + collateral)"
            )
        <*> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Where to write intent.json (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help
                        "Where to write step-by-step trace lines (defaults to stderr)"
                )
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> wizardOrderP
        <*> wizardRateP
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "HOURS"
                    <> help
                        "Optional. Omit to use the chain's \
                        \current horizon (longest safe slot)."
                )
            )
        <*> strOption
            ( long "description"
                <> metavar "TEXT"
                <> help "Rationale: description"
            )
        <*> strOption
            ( long "justification"
                <> metavar "TEXT"
                <> help "Rationale: justification"
            )
        <*> strOption
            ( long "destination-label"
                <> metavar "TEXT"
                <> help "Rationale: destination label"
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event override (defaults disburse)"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help "Rationale label override (defaults Swap ADA<->USDM)"
                )
            )
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> long "signer"
                    <> metavar "SCOPE|HEX"
                    <> help
                        "Repeat for each extra signer (scope name/alias or 28-byte hex)"
                )
            )
        <*> (ExclusionSet <$> excludeUtxoP)
        <*> (ForcedInclusionSet <$> extraTxInP)

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

wizardOrderP :: Parser WizardOrder
wizardOrderP = fixedUsdmP <|> allAdaP
  where
    fixedUsdmP =
        FixedUsdm
            <$> option
                auto
                ( long "usdm"
                    <> metavar "USDM"
                    <> help
                        "Target USDM amount (decimals OK; e.g. 100000). The ADA spend is derived as usdm / min-rate."
                )
            <*> chunkSpecP
    allAdaP =
        AllAda
            <$> ( flag'
                    ()
                    ( long "all-ada"
                        <> help
                            "Swap the maximum spendable pure ADA from the selected treasury scope. Requires --split and is mutually exclusive with --usdm."
                    )
                    *> option
                        positiveSplit
                        ( long "split"
                            <> metavar "INT"
                            <> help
                                "Split the all-ADA order into N equal chunks (N >= 1)"
                        )
                )

chunkSpecP :: Parser ChunkSpec
chunkSpecP =
    SplitCount
        <$> option
            positiveSplit
            ( long "split"
                <> metavar "INT"
                <> help "Split the order into N equal chunks (N >= 1)"
            )
        <|> ChunkUsdm
            <$> option
                auto
                ( long "chunk-usdm"
                    <> metavar "USDM"
                    <> help
                        "Per-chunk USDM size (alternative to --split; decimals OK)"
                )

positiveSplit :: ReadM Int
positiveSplit = eitherReader $ \s -> case reads s of
    [(n, "")]
        | n >= 1 -> Right n
        | otherwise -> Left "--split must be a positive integer (>= 1)"
    _ -> Left ("--split: not an integer: " <> s)

wizardRateP :: Parser WizardRate
wizardRateP =
    explicitMinRateP <|> overrideRateP
  where
    explicitMinRateP =
        WizardMinRate
            <$> option
                auto
                ( long "min-rate"
                    <> metavar "USDM_PER_ADA"
                    <> help "Min acceptable rate, e.g. 0.245 (no slippage applied)"
                )
    overrideRateP =
        WizardOverrideRate
            <$> option
                auto
                ( long "ada-usdm"
                    <> metavar "USDM_PER_ADA"
                    <> help
                        "Operator-supplied ADA/USDM quote, e.g. 0.270. Paired with \
                        \--slippage-bps to derive min-rate. For a live quote, run \
                        \swap-quote instead and pipe its intent into tx-build."
                )
            <*> option
                slippageReader
                ( long "slippage-bps"
                    <> metavar "INT"
                    <> help
                        "Derive min-rate from --ada-usdm with explicit slippage in basis points; 0 <= INT < 10000"
                )

usdmToLovelace :: Double -> Double -> Integer
usdmToLovelace usdm rate =
    round (toRational usdm * 1_000_000 / toRational rate)

rateToFraction :: Double -> (Integer, Integer)
rateToFraction r =
    (round (toRational r * 1_000_000), 1_000_000)

swapQuoteRequestChunk :: ChunkSpec -> SQ.SwapQuoteRequestChunk
swapQuoteRequestChunk = \case
    SplitCount n ->
        SQ.SplitInto n
    ChunkUsdm x ->
        SQ.ChunkUsdm (toRational x)

traceAllAdaPlan
    :: Tracer IO WizardEvent
    -> AllAdaPlan
    -> Int
    -> IO ()
traceAllAdaPlan tr plan requestedSplit =
    traceWith tr $
        WeAllAdaPlan
            (aapSelectedTreasuryUtxos plan)
            (aapAvailableLovelace plan)
            (aapAmountLovelace plan)
            (aapImpliedUsdm plan)
            (aapLeftoverLovelace plan)
            (toInteger requestedSplit)
            (aapChunkCount plan)
            (aapExtraPerChunkLovelace plan)
            (aapOverheadLovelace plan)
            (aapRateNumerator plan)
            (aapRateDenominator plan)

{- | Pre-flight check for @--exclude-utxo@ / @--extra-tx-in@
contradictions. Returns 'Left' (Contradiction refs) when an
outref appears in both flag sets on the same invocation;
runs before any chain query so the wizard can fail fast.
-}
validateWizardInputControl
    :: WizardOpts -> Either InputControlError ()
validateWizardInputControl WizardOpts{..} =
    validateInputControl wOptsExcludeSet wOptsForcedSet
