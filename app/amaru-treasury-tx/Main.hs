{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : amaru-treasury-tx CLI entry point
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parses CLI arguments, wires up the local-node 'Provider'
backend, dispatches to the matching transaction-build
program, re-evaluates every redeemer against the final
tx, and emits an unsigned Conway transaction CBOR (hex)
on stdout (or a path).

Subcommands:

* @tx-build [--intent path\/to\/intent.json] [--out path\/tx.cbor] [--log path\/build.log] [--report path\/report.json]@ —
  builds any supported treasury tx from a unified
  'SomeTreasuryIntent'. With no @--intent@, reads the intent JSON from
  stdin so wizard-produced intents can pipe cleanly into the unified
  builder.
* @swap-wizard --network <preprod|mainnet> --wallet-addr ... --metadata path\/to\/metadata.json --scope ... --usdm N.NN --split N --min-rate N.NN --validity-hours N --description ... --justification ... --destination-label ... [--extra-signer SCOPE|HEX]... [--out path\/intent.json] [--log path\/wizard.log]@
  produces a swap @intent.json@ from a typed questionnaire.
  The rate can also be derived from @--ada-usd@, @--ada-usdm@, or
  @--price-source@ plus @--slippage-bps@ while keeping the same stdout
  intent contract.
  See [@specs\/002-swap-wizard\/quickstart.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/quickstart.md).
* @swap-quote --wallet-addr ... --metadata path\/to\/metadata.json --scope ... --usdm N.NN --split N (--ada-usd N.NN | --ada-usdm N.NN | --price-source SOURCE) --slippage-bps N --validity-hours N --description ... --justification ... --destination-label ... --out-dir path\/run-dir@
  derives swap parameters from a quote, writes @intent.json@ and @params.json@,
  and builds unsigned CBOR through the existing transaction builder.
* @withdraw-wizard --network <preprod|mainnet> --wallet-addr ... --metadata path\/to\/metadata.json --scope ... --validity-hours N [--description ...] [--justification ...] [--destination-label ...] [--out path\/intent.json] [--log path\/wizard.log]@
  produces a withdraw @intent.json@ from resolved registry and reward state.
-}
module Main (main) where

import Control.Applicative ((<|>))
import Control.Exception
    ( IOException
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Options.Applicative
    ( Parser
    , ParserInfo
    , ReadM
    , auto
    , command
    , eitherReader
    , execParser
    , fullDesc
    , help
    , helper
    , hsubparser
    , info
    , long
    , many
    , metavar
    , option
    , optional
    , progDesc
    , short
    , strOption
    , (<**>)
    )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64, Word8)
import Lens.Micro ((^.))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Data.Set qualified as Set

import Cardano.Ledger.Api.Tx.Out (valueTxOutL)
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    )

import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.Backend.N2C
    ( StakeRewardsError (..)
    , findSocketMagic
    , probeNetworkMagic
    , queryStakeRewardsLovelace
    , withLocalNodeBackend
    )
import Amaru.Treasury.ChainContext (liveContext)
import Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts (..)
    , SwapQuotePaths (..)
    , SwapQuotePlan (..)
    , SwapQuoteQuoteArg (..)
    , SwapQuoteRunDecision (..)
    , decideSwapQuoteRun
    , deriveSwapQuotePlan
    , quoteP
    , slippageReader
    , swapQuoteOptsP
    , swapQuotePaths
    )
import Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , txBuildOptsP
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , parseRewardAccountForNetwork
    , parseTxIn
    )
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , ReportContext (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , buildTransactionReport
    , encodeBuildOutput
    , txCborHexFromBytes
    )
import Amaru.Treasury.Report.Cli
    ( ReportRenderOpts (..)
    , decodeReportRenderInput
    , renderReportRenderOutput
    , reportRenderOptsP
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.TreasuryBuild
    ( ScriptResult (..)
    , TreasuryBuildResult (..)
    , renderTreasuryBuildError
    , runFromIntent
    , runFromIntentEither
    , treasuryBuildErrorCode
    )
import Amaru.Treasury.TreasuryBuild.ReportWriter
    ( writeReportArtifact
    )
import Amaru.Treasury.TreasuryBuild.Trace
    ( BuildEvent (..)
    , buildEventTracer
    )
import Amaru.Treasury.Tx.SwapQuote
    ( AffordabilityFailure (..)
    , DerivedSwapParameters (..)
    , QuoteObservation
    , SlippageBps
    , SwapQuoteAudit (..)
    , renderAffordabilityFailure
    , writeSwapQuoteAudit
    )
import Amaru.Treasury.Tx.SwapQuote qualified as SQ
import Amaru.Treasury.Tx.SwapQuote.Source
    ( coingeckoAdaUsdProvider
    , fetchQuoteSource
    , renderQuoteSourceError
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants (..)
    , RationaleAnswers (..)
    , RegistryView (..)
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , SwapWizardQ (..)
    , TreasuryRefs (..)
    , TreasurySelection (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , WizardError
    , networkConstants
    , registryViewFromVerified
    , renderWalletShortfall
    , resolveWizardEnv
    , txInToText
    , wizardToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw
import Amaru.Treasury.Tx.WithdrawWizard.Trace qualified as WithdrawTrace
import Control.Tracer (Tracer (..), traceWith)

data GlobalOpts = GlobalOpts
    { goSocketPath :: !(Maybe FilePath)
    , goNetworkMagic :: !NetworkMagic
    , goNetworkName :: !(Maybe Text)
    -- ^ canonical name when known
    --   ('Nothing' for magics like @42@ that have no
    --   well-known name).
    }

data Cmd
    = CmdSwapWizard WizardOpts
    | CmdSwapQuote SwapQuoteOpts
    | CmdWithdrawWizard WithdrawOpts
    | CmdTxBuild TxBuildOpts
    | CmdReportRender ReportRenderOpts

{- | Two ways to express how a swap is sliced:
  * @SplitCount n@: split into @n@ approximately equal chunks
    (per-chunk size = @amount \`div\` n@; one extra small remainder
    chunk if not exact).
  * @ChunkUsdm d@: a fixed per-chunk USDM target; the chunk's
    ADA size is derived from the @--min-rate@.
-}
data ChunkSpec
    = SplitCount !Int
    | ChunkUsdm !Double

data WizardRate
    = WizardMinRate !Double
    | WizardQuoteRate !SwapQuoteQuoteArg !SlippageBps

data WizardSwapParameters = WizardSwapParameters
    { wspAmountLovelace :: !Integer
    , wspChunkSizeLovelace :: !Integer
    , wspRateNumerator :: !Integer
    , wspRateDenominator :: !Integer
    }

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
    , wOptsUsdm :: !Double
    -- ^ target USDM amount (whole USDM, decimals OK).
    --   The wizard derives the ADA spend from
    --   @usdm \/ min-rate@.
    , wOptsChunkSpec :: !ChunkSpec
    -- ^ how to split the amount into chunks
    , wOptsRate :: !WizardRate
    -- ^ minimum acceptable USDM per ADA, either explicit or quote-derived
    , wOptsValidityHours :: !Word8
    , wOptsDescription :: !Text
    , wOptsJustification :: !Text
    , wOptsDestinationLabel :: !Text
    , wOptsEvent :: !(Maybe Text)
    , wOptsLabel :: !(Maybe Text)
    , wOptsSigners :: ![Text]
    -- ^ accumulated extra-signer flags; empty = selected
    --   scope owner only.
    }

{- | Flags for the @withdraw-wizard@ subcommand.
Mirrors @specs/006-withdraw-wizard/contracts/withdraw-wizard-cli.md@.
-}
data WithdrawOpts = WithdrawOpts
    { wdOptsWalletAddr :: !Text
    , wdOptsMetadataPath :: !FilePath
    , wdOptsOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , wdOptsLog :: !(Maybe FilePath)
    -- ^ where to send 'WithdrawWizardEvent' lines. 'Nothing' = stderr.
    , wdOptsScope :: !ScopeId
    , wdOptsValidityHours :: !Word8
    , wdOptsDescription :: !(Maybe Text)
    , wdOptsJustification :: !(Maybe Text)
    , wdOptsDestinationLabel :: !(Maybe Text)
    , wdOptsEvent :: !(Maybe Text)
    , wdOptsLabel :: !(Maybe Text)
    }

globalOptsP :: Parser GlobalOpts
globalOptsP =
    mkOpts
        <$> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> ( byName <|> byMagic <|> pure defaultMainnet
            )
  where
    byName =
        option
            (eitherReader networkNameToPair)
            ( long "network"
                <> metavar "NAME"
                <> help
                    "mainnet | preprod | preview (alternative to --network-magic)"
            )
    byMagic =
        (\m -> (NetworkMagic m, networkMagicNameMaybe (NetworkMagic m)))
            <$> option
                auto
                ( long "network-magic"
                    <> metavar "WORD32"
                    <> help
                        "Custom network magic (mainnet=764824073, preprod=1, preview=2)"
                )
    defaultMainnet =
        ( NetworkMagic 764_824_073
        , Just "mainnet"
        )
    mkOpts socket (magic, name) =
        GlobalOpts
            { goSocketPath = socket
            , goNetworkMagic = magic
            , goNetworkName = name
            }

{- | Parse a canonical network name to its
@(magic, Just name)@ pair.
-}
networkNameToPair
    :: String -> Either String (NetworkMagic, Maybe Text)
networkNameToPair s = case s of
    "mainnet" ->
        Right (NetworkMagic 764_824_073, Just "mainnet")
    "preprod" -> Right (NetworkMagic 1, Just "preprod")
    "preview" -> Right (NetworkMagic 2, Just "preview")
    _ ->
        Left
            ( "unknown network name: "
                <> s
                <> " (expected mainnet|preprod|preview)"
            )

-- | Reverse lookup: known magics to canonical names.
networkMagicNameMaybe :: NetworkMagic -> Maybe Text
networkMagicNameMaybe (NetworkMagic m) = case m of
    764824073 -> Just "mainnet"
    1 -> Just "preprod"
    2 -> Just "preview"
    _ -> Nothing

cmdP :: Parser Cmd
cmdP =
    hsubparser
        ( command
            "tx-build"
            ( info
                (CmdTxBuild <$> txBuildOptsP)
                ( progDesc
                    "Build any treasury transaction from a unified intent.json"
                )
            )
            <> command
                "report-render"
                ( info
                    (CmdReportRender <$> reportRenderOptsP)
                    ( progDesc
                        "Render a tx-build report envelope as Markdown"
                    )
                )
            <> command
                "swap-wizard"
                ( info
                    (CmdSwapWizard <$> wizardOptsP)
                    ( progDesc
                        "Produce a swap intent.json from a typed questionnaire"
                    )
                )
            <> command
                "swap-quote"
                ( info
                    (CmdSwapQuote <$> swapQuoteOptsP)
                    ( progDesc
                        "Prepare a quote-derived swap run"
                    )
                )
            <> command
                "withdraw-wizard"
                ( info
                    (CmdWithdrawWizard <$> withdrawOptsP)
                    ( progDesc
                        "Produce a withdraw intent.json from registry and reward state"
                    )
                )
        )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

{- | Reject a non-positive @--split@ at parse time. The wizard
divides the total amount by this number; @0@ would be a silent
no-op (one chunk of the full amount), @< 0@ would flip the sign.
-}
positiveSplit :: ReadM Int
positiveSplit = eitherReader $ \s -> case reads s of
    [(n, "")]
        | n >= 1 -> Right n
        | otherwise -> Left "--split must be a positive integer (>= 1)"
    _ -> Left ("--split: not an integer: " <> s)

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
        <*> option
            auto
            ( long "usdm"
                <> metavar "USDM"
                <> help
                    "Target USDM amount (decimals OK; e.g. 100000). The ADA spend is derived as usdm / min-rate."
            )
        <*> ( SplitCount
                <$> option
                    positiveSplit
                    ( long "split"
                        <> metavar "INT"
                        <> help
                            "Split the order into N equal chunks (N >= 1)"
                    )
                <|> ChunkUsdm
                    <$> option
                        auto
                        ( long "chunk-usdm"
                            <> metavar "USDM"
                            <> help
                                "Per-chunk USDM size (alternative to --split; decimals OK)"
                        )
            )
        <*> wizardRateP
        <*> option
            auto
            ( long "validity-hours"
                <> metavar "HOURS"
                <> help "Validity window from tip; 1..48"
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

wizardRateP :: Parser WizardRate
wizardRateP =
    explicitMinRateP <|> quoteDerivedRateP
  where
    explicitMinRateP =
        WizardMinRate
            <$> option
                auto
                ( long "min-rate"
                    <> metavar "USDM_PER_ADA"
                    <> help "Min acceptable rate, e.g. 0.245"
                )
    quoteDerivedRateP =
        WizardQuoteRate
            <$> quoteP
            <*> option
                slippageReader
                ( long "slippage-bps"
                    <> metavar "INT"
                    <> help
                        "Derive min-rate from quote after explicit slippage policy in basis points; 0 <= INT < 10000"
                )

withdrawOptsP :: Parser WithdrawOpts
withdrawOptsP =
    WithdrawOpts
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
        <*> option
            auto
            ( long "validity-hours"
                <> metavar "HOURS"
                <> help "Validity window from tip; 1..48"
            )
        <*> optional
            ( strOption
                ( long "description"
                    <> metavar "TEXT"
                    <> help
                        "Rationale description override"
                )
            )
        <*> optional
            ( strOption
                ( long "justification"
                    <> metavar "TEXT"
                    <> help
                        "Rationale justification override"
                )
            )
        <*> optional
            ( strOption
                ( long "destination-label"
                    <> metavar "TEXT"
                    <> help
                        "Rationale destination label override"
                )
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event override (defaults withdraw)"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help
                        "Rationale label override (defaults Withdraw treasury rewards)"
                )
            )

{- | Convert a USDM amount + USDM\/ADA rate to lovelace:
@lovelace = round (usdm * 1_000_000 \/ rate)@.

The CLI parses both inputs as 'Double' (Read), but we promote
them to 'Rational' before any arithmetic so the multiplication
and division do not compound the Double round-trip error.
The result is correct to within ~1 ulp of the operator-supplied
@--usdm@ \/ @--min-rate@, with no further drift introduced by
intermediate floating-point ops.
-}
usdmToLovelace :: Double -> Double -> Integer
usdmToLovelace usdm rate =
    round (toRational usdm * 1_000_000 / toRational rate)

{- | Convert decimal USDM-per-ADA rate to (numerator, denominator).
Fixed denominator 1_000_000 matches USDM's 6-decimal precision.
The conversion is done in 'Rational' to avoid Double drift during
the @r * 1_000_000@ scaling.
-}
rateToFraction :: Double -> (Integer, Integer)
rateToFraction r =
    (round (toRational r * 1_000_000), 1_000_000)

resolveWizardSwapParameters
    :: Tracer IO WizardEvent
    -> Text
    -> Double
    -> ChunkSpec
    -> WizardRate
    -> IO WizardSwapParameters
resolveWizardSwapParameters tr observedAt usdm chunkSpec = \case
    WizardMinRate minRate ->
        let amountLov = usdmToLovelace usdm minRate
            chunkSize = case chunkSpec of
                -- 'positiveSplit' rejects N < 1 at parse time.
                SplitCount n -> amountLov `div` toInteger n
                ChunkUsdm x -> usdmToLovelace x minRate
            (rateNum, rateDen) = rateToFraction minRate
        in  pure
                WizardSwapParameters
                    { wspAmountLovelace = amountLov
                    , wspChunkSizeLovelace = chunkSize
                    , wspRateNumerator = rateNum
                    , wspRateDenominator = rateDen
                    }
    WizardQuoteRate quoteArg slippage -> do
        observation <- resolveSwapQuoteObservation tr observedAt quoteArg
        derived <-
            case SQ.deriveSwapParameters
                observation
                slippage
                SQ.SwapQuoteRequest
                    { SQ.sqrRequestedUsdm = toRational usdm
                    , SQ.sqrChunk = swapQuoteRequestChunk chunkSpec
                    } of
                Right value ->
                    pure value
                Left err ->
                    abortTr tr ("derive swap parameters: " <> T.pack (show err))
        pure
            WizardSwapParameters
                { wspAmountLovelace = SQ.dspAmountLovelace derived
                , wspChunkSizeLovelace = SQ.dspChunkSizeLovelace derived
                , wspRateNumerator = SQ.dspRateNumerator derived
                , wspRateDenominator = SQ.dspRateDenominator derived
                }

swapQuoteRequestChunk :: ChunkSpec -> SQ.SwapQuoteRequestChunk
swapQuoteRequestChunk = \case
    SplitCount n ->
        SQ.SplitInto n
    ChunkUsdm x ->
        SQ.ChunkUsdm (toRational x)

{- | Resolve the canonical network name from
'GlobalOpts'. Returns 'Left' if the user passed a custom
@--network-magic@ that does not match any known network.
-}
resolveNetworkName :: GlobalOpts -> Either String Text
resolveNetworkName g = case goNetworkName g of
    Just n -> Right n
    Nothing ->
        let NetworkMagic m = goNetworkMagic g
        in  Left
                ( "swap-wizard: --network-magic "
                    <> show m
                    <> " is not a known network; pass "
                    <> "--network mainnet|preprod|preview "
                    <> "or a known magic"
                )

opts :: ParserInfo (GlobalOpts, Cmd)
opts =
    info
        ( ((,) <$> globalOptsP <*> cmdP)
            <**> helper
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )

main :: IO ()
main = do
    (g, c) <- execParser opts
    case c of
        CmdReportRender ro ->
            runReportRender ro
        CmdSwapWizard wo ->
            withSocket g $ \socket ->
                runWizard g{goSocketPath = Just socket} wo
        CmdSwapQuote qo ->
            withSocket g $ \socket ->
                runSwapQuote g{goSocketPath = Just socket} qo
        CmdWithdrawWizard wo ->
            withSocket g $ \socket ->
                runWithdrawWizard g{goSocketPath = Just socket} wo
        CmdTxBuild to ->
            withSocket g $ \socket ->
                runTxBuild socket to

withSocket :: GlobalOpts -> (FilePath -> IO a) -> IO a
withSocket g action = do
    socket <- resolveSocket (goSocketPath g)
    action socket

runReportRender :: ReportRenderOpts -> IO ()
runReportRender ReportRenderOpts{..} = do
    metadata <- loadReportRenderMetadata rrMetadataPath
    bytes <- case rrInPath of
        Nothing -> BS.hGetContents IO.stdin
        Just path -> BS.readFile path
    output <- case decodeReportRenderInput bytes of
        Left err -> do
            TIO.hPutStrLn stderr err
            exitWith (ExitFailure 3)
        Right decoded -> pure decoded
    rendered <- case renderReportRenderOutput metadata output of
        Left err -> do
            TIO.hPutStrLn stderr err
            exitWith (ExitFailure 5)
        Right text -> pure text
    writeRenderedReport rrOutPath rendered

loadReportRenderMetadata
    :: Maybe FilePath -> IO (Maybe TreasuryMetadata)
loadReportRenderMetadata requestedPath = do
    metadataPath <- case requestedPath of
        Just path -> pure (Just path)
        Nothing -> do
            exists <- doesFileExist defaultReportRenderMetadataPath
            pure $
                if exists
                    then Just defaultReportRenderMetadataPath
                    else Nothing
    case metadataPath of
        Nothing -> pure Nothing
        Just path -> do
            result <-
                try (readMetadataFile path)
                    :: IO (Either SomeException TreasuryMetadata)
            case result of
                Right metadata -> pure (Just metadata)
                Left err -> do
                    TIO.hPutStrLn
                        stderr
                        ( "report-render: metadata read failed "
                            <> T.pack path
                            <> ": "
                            <> T.pack (displayException err)
                        )
                    exitWith (ExitFailure 3)

defaultReportRenderMetadataPath :: FilePath
defaultReportRenderMetadataPath = "journal/2026/metadata.json"

writeRenderedReport :: Maybe FilePath -> Text -> IO ()
writeRenderedReport Nothing text =
    TIO.putStr text
writeRenderedReport (Just path) text = do
    result <- try (TIO.writeFile path text) :: IO (Either IOException ())
    case result of
        Right () -> pure ()
        Left err -> do
            TIO.hPutStrLn
                stderr
                ( "report-render: output write failed "
                    <> T.pack path
                    <> ": "
                    <> T.pack (displayException err)
                )
            exitWith (ExitFailure 4)

resolveSocket :: Maybe FilePath -> IO FilePath
resolveSocket (Just p) = pure p
resolveSocket Nothing = do
    mEnv <- lookupEnv "CARDANO_NODE_SOCKET_PATH"
    case mEnv of
        Just p -> pure p
        Nothing ->
            throwIO . userError $
                "amaru-treasury-tx: pass --node-socket "
                    <> "or set CARDANO_NODE_SOCKET_PATH"

-- The legacy 'swap' subcommand (runSwap, abortSwap) was
-- removed in T028 alongside the per-action build modules
-- (Tx.SwapBuild, Tx.Swap.Trace). Use 'tx-build' (above)
-- instead — the unified entry point for any treasury action.

-- ----------------------------------------------------
-- swap-wizard subcommand
-- ----------------------------------------------------

runWizard :: GlobalOpts -> WizardOpts -> IO ()
runWizard g WizardOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    -- Open log handle and build the typed tracer first;
    -- every subsequent step is one trace event.
    withLogHandle wOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = eventTracer textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortTr tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith tr (WeNetwork networkName (fromIntegral magic))
        traceWith tr (WeMetadata wOptsMetadataPath)

        -- Convert human-friendly answers to wire types.
        observedAt <- currentIso8601
        params <-
            resolveWizardSwapParameters
                tr
                observedAt
                wOptsUsdm
                wOptsChunkSpec
                wOptsRate
        let amountLov = wspAmountLovelace params
            chunkSize = wspChunkSizeLovelace params
            answers =
                SwapWizardQ
                    { wqScope = wOptsScope
                    , wqAmountLovelace = amountLov
                    , wqChunkSizeLovelace = chunkSize
                    , wqRateNumerator = wspRateNumerator params
                    , wqRateDenominator = wspRateDenominator params
                    , wqValidityHours = wOptsValidityHours
                    , wqRationale =
                        RationaleAnswers
                            { raDescription = wOptsDescription
                            , raJustification = wOptsJustification
                            , raDestinationLabel =
                                wOptsDestinationLabel
                            , raEvent = wOptsEvent
                            , raLabel = wOptsLabel
                            }
                    , wqExtraSigners = wOptsSigners
                    }

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        wOptsMetadataPath
                        (Set.singleton wOptsScope)
                rv <- case verified of
                    Left e ->
                        abortTr tr ("verify: " <> T.pack (show e))
                    Right registry ->
                        case registryViewFromVerified
                            wOptsScope
                            registry of
                            Left e ->
                                abortTr
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                traceRegistryView tr wOptsScope rv
                let ri =
                        ResolverInput
                            { riNetwork = networkName
                            , riWalletAddrBech32 = wOptsWalletAddr
                            , riScope = wOptsScope
                            , riAmountLovelace = amountLov
                            , riChunkSizeLovelace = chunkSize
                            , riRegistry = rv
                            }
                let renv =
                        traceResolverEnv tr $
                            providerToResolverEnv backend
                er <- resolveWizardEnv renv ri
                env <- case er of
                    Left (ResolverWalletShortfall avail required) ->
                        abortTr tr (renderWalletShortfall ri avail required)
                    Left e ->
                        abortTr tr ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceEnv tr env
                intent <-
                    case wizardToTreasuryIntent env answers of
                        Left we ->
                            abortTr
                                tr
                                ( "translate: "
                                    <> T.pack
                                        (show (we :: WizardError))
                                )
                        Right i -> pure i
                let p = tiPayload intent
                    total = swiAmountLovelace p
                    cs = swiChunkSizeLovelace p
                    full = total `div` cs
                    rem' = total `mod` cs
                traceWith tr $
                    WeValidityComputed
                        (weCurrentTip env)
                        (tiValidityUpperBoundSlot intent)
                traceWith tr $
                    WeChunksComputed total cs (fromInteger full) rem'
                traceWith tr (WeIntentReady wOptsOut)
                let bytes =
                        encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SSwap intent)
                case wOptsOut of
                    Nothing -> BSL.putStr bytes
                    Just fp -> BSL.writeFile fp bytes

-- ----------------------------------------------------
-- swap-quote subcommand
-- ----------------------------------------------------

runSwapQuote :: GlobalOpts -> SwapQuoteOpts -> IO ()
runSwapQuote g quoteOpts@SwapQuoteOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
        paths = swapQuotePaths sqoOutDir
    createDirectoryIfMissing True sqoOutDir
    observedAt <- currentIso8601
    withLogHandle (Just (sqpWizardLog paths)) $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = eventTracer textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortTr tr (T.pack e)
        observation <- resolveSwapQuoteObservation tr observedAt sqoQuote
        plan <- case deriveSwapQuotePlan networkName quoteOpts observation of
            Right p -> pure p
            Left e -> abortTr tr ("swap-quote: " <> T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith tr (WeNetwork networkName (fromIntegral magic))
        traceWith tr (WeMetadata sqoMetadataPath)

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        sqoMetadataPath
                        (Set.singleton sqoScope)
                rv <- case verified of
                    Left e ->
                        abortTr tr ("verify: " <> T.pack (show e))
                    Right registry ->
                        case registryViewFromVerified
                            sqoScope
                            registry of
                            Left e ->
                                abortTr
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                traceRegistryView tr sqoScope rv
                let ri =
                        sqpResolverInput plan $
                            ResolverInput
                                { riNetwork = networkName
                                , riWalletAddrBech32 = sqoWalletAddr
                                , riScope = sqoScope
                                , riAmountLovelace =
                                    dspAmountLovelace (sqpDerived plan)
                                , riChunkSizeLovelace =
                                    dspChunkSizeLovelace (sqpDerived plan)
                                , riRegistry = rv
                                }
                    renv =
                        traceResolverEnv tr $
                            providerToResolverEnv backend
                er <- resolveWizardEnv renv ri
                env <- case er of
                    Left (ResolverShortfall avail _required) ->
                        abortSwapQuoteAffordability
                            tr
                            observedAt
                            plan
                            networkName
                            avail
                    Left (ResolverWalletShortfall avail required) ->
                        abortTr tr (renderWalletShortfall ri avail required)
                    Left e ->
                        abortTr tr ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceEnv tr env
                intent <-
                    case wizardToTreasuryIntent env (sqpAnswers plan) of
                        Left we ->
                            abortTr
                                tr
                                ( "translate: "
                                    <> T.pack
                                        (show (we :: WizardError))
                                )
                        Right i -> pure i
                let p = tiPayload intent
                    total = swiAmountLovelace p
                    cs = swiChunkSizeLovelace p
                    full = total `div` cs
                    rem' = total `mod` cs
                    generatedChunks = full + if rem' > 0 then 1 else 0
                    extraPerChunk =
                        ncExtraPerChunkLovelace (weNetworkConstants env)
                    selectedTreasuryLovelace =
                        total
                            + generatedChunks * extraPerChunk
                            + tsLeftoverLovelace
                                (weTreasurySelection env)
                    decision =
                        decideSwapQuoteRun
                            plan
                            extraPerChunk
                            selectedTreasuryLovelace
                case decision of
                    SwapQuoteRunBlocked failure audit ->
                        writeAndAbortSwapQuoteAudit
                            tr
                            observedAt
                            plan
                            failure
                            audit
                    SwapQuoteRunAllowed _summary audit -> do
                        traceWith tr $
                            WeValidityComputed
                                (weCurrentTip env)
                                (tiValidityUpperBoundSlot intent)
                        traceWith tr $
                            WeChunksComputed total cs (fromInteger full) rem'
                        traceWith tr (WeIntentReady (Just (sqpIntentJson paths)))
                        BSL.writeFile
                            (sqpIntentJson paths)
                            ( encodeSomeTreasuryIntent
                                (SomeTreasuryIntent SSwap intent)
                            )
                        runSwapQuoteBuild
                            socket
                            (sqpBuildLog paths)
                            (sqpUnsignedCborHex paths)
                            (SomeTreasuryIntent SSwap intent)
                        writeSwapQuoteAudit
                            (sqpParamsJson paths)
                            (stampSwapQuoteAudit observedAt audit)

currentIso8601 :: IO Text
currentIso8601 =
    T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
        <$> getCurrentTime

resolveSwapQuoteObservation
    :: Tracer IO WizardEvent
    -> Text
    -> SwapQuoteQuoteArg
    -> IO QuoteObservation
resolveSwapQuoteObservation tr observedAt = \case
    SwapQuoteOverride observation ->
        pure observation
    SwapQuoteSource source -> do
        result <- fetchQuoteSource coingeckoAdaUsdProvider source observedAt
        case result of
            Right observation ->
                pure observation
            Left err ->
                abortTr tr (renderQuoteSourceError err)

abortSwapQuoteAffordability
    :: Tracer IO WizardEvent
    -> Text
    -> SwapQuotePlan
    -> Text
    -> Integer
    -> IO a
abortSwapQuoteAffordability tr observedAt plan networkName available =
    case networkConstants networkName of
        Left e ->
            abortTr tr (T.pack e)
        Right nc ->
            case decideSwapQuoteRun
                plan
                (ncExtraPerChunkLovelace nc)
                available of
                SwapQuoteRunBlocked failure audit ->
                    writeAndAbortSwapQuoteAudit
                        tr
                        observedAt
                        plan
                        failure
                        audit
                SwapQuoteRunAllowed{} ->
                    abortTr tr "resolve: treasury affordability changed during resolution"

writeAndAbortSwapQuoteAudit
    :: Tracer IO WizardEvent
    -> Text
    -> SwapQuotePlan
    -> AffordabilityFailure
    -> SwapQuoteAudit
    -> IO a
writeAndAbortSwapQuoteAudit tr observedAt plan failure audit = do
    writeSwapQuoteAudit
        (sqpParamsJson (sqpPaths plan))
        (stampSwapQuoteAudit observedAt audit)
    abortTr tr (renderAffordabilityFailure failure)

stampSwapQuoteAudit
    :: Text
    -> SwapQuoteAudit
    -> SwapQuoteAudit
stampSwapQuoteAudit observedAt audit =
    audit{sqaObservedAt = observedAt}

runSwapQuoteBuild
    :: FilePath
    -> FilePath
    -> FilePath
    -> SomeTreasuryIntent
    -> IO ()
runSwapQuoteBuild socket logPath cborPath some =
    withLogHandle (Just logPath) $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = buildEventTracer textTracer
        let (actionName, netName) =
                case some of
                    SomeTreasuryIntent _sa intent ->
                        ( T.pack
                            (drop 1 (show (tiSAction intent)))
                        , tiNetwork intent
                        )
        traceWith tr (TbeIntentParsed actionName netName)
        magic <- case netName of
            "mainnet" -> pure (NetworkMagic 764_824_073)
            "preprod" -> pure (NetworkMagic 1)
            "preview" -> pure (NetworkMagic 2)
            other ->
                abortBuild
                    tr
                    ("unknown network in intent: " <> other)
        traceWith tr (TbeConnect socket)
        required <- case requiredUtxos some of
            Left e ->
                abortBuild tr ("required UTxOs: " <> T.pack e)
            Right s -> pure s
        traceWith
            tr
            (TbeRequiredUtxos (Set.size required))
        ok <- probeNetworkMagic magic socket
        if ok
            then
                traceWith
                    tr
                    ( TbeNetworkOk
                        netName
                        (unNetworkMagic magic)
                    )
            else do
                socketMagic <-
                    findSocketMagic
                        (`probeNetworkMagic` socket)
                        netName
                traceWith
                    tr
                    ( TbeNetworkMismatch
                        netName
                        (unNetworkMagic magic)
                        socketMagic
                    )
                exitWith (ExitFailure 6)
        withLocalNodeBackend magic socket $ \backend -> do
            ctx <- liveContext backend required
            tbr <- runFromIntent ctx some
            let cborStrict = BSL.toStrict (tbrCborBytes tbr)
                hexed = B16.encode cborStrict
                Coin feeLov = tbrFeeLovelace tbr
                Coin tcLov = tbrTotalCollateralLovelace tbr
                failures =
                    [ (purpose, e)
                    | ScriptResult purpose (Left e) <-
                        tbrScriptResults tbr
                    ]
            traceWith
                tr
                ( TbeBuilt
                    (BS.length cborStrict)
                    feeLov
                    tcLov
                )
            traceWith
                tr
                ( TbeReevaluated
                    (length (tbrScriptResults tbr))
                    (length failures)
                )
            mapM_
                ( \(p, e) ->
                    traceWith
                        tr
                        ( TbeScriptFail
                            (T.pack (show p))
                            (T.pack e)
                        )
                )
                failures
            BS.writeFile cborPath hexed
            traceWith tr (TbeWroteCbor (Just cborPath))
            if null failures
                then traceWith tr TbeValidationOk
                else do
                    traceWith tr TbeValidationFailed
                    exitFailure

-- ----------------------------------------------------
-- withdraw-wizard subcommand
-- ----------------------------------------------------

runWithdrawWizard :: GlobalOpts -> WithdrawOpts -> IO ()
runWithdrawWizard g WithdrawOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle wdOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = WithdrawTrace.withdrawWizardEventTracer textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortWithdraw tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith
            tr
            ( WithdrawTrace.WweNetwork
                networkName
                (fromIntegral magic)
            )
        traceWith tr (WithdrawTrace.WweMetadata wdOptsMetadataPath)

        let answers =
                Withdraw.WithdrawAnswers
                    { Withdraw.waScope = wdOptsScope
                    , Withdraw.waValidityHours =
                        wdOptsValidityHours
                    , Withdraw.waDescription =
                        wdOptsDescription
                    , Withdraw.waJustification =
                        wdOptsJustification
                    , Withdraw.waDestinationLabel =
                        wdOptsDestinationLabel
                    , Withdraw.waEvent = wdOptsEvent
                    , Withdraw.waLabel = wdOptsLabel
                    }

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        wdOptsMetadataPath
                        (Set.singleton wdOptsScope)
                rv <- case verified of
                    Left e ->
                        abortWithdraw
                            tr
                            ("verify: " <> T.pack (show e))
                    Right registry ->
                        case Withdraw.registryViewFromVerified
                            wdOptsScope
                            registry of
                            Left e ->
                                abortWithdraw
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                traceWithdrawRegistryView tr wdOptsScope rv
                let ri =
                        Withdraw.WithdrawResolverInput
                            { Withdraw.wriNetwork = networkName
                            , Withdraw.wriWalletAddrBech32 =
                                wdOptsWalletAddr
                            , Withdraw.wriScope = wdOptsScope
                            , Withdraw.wriRegistry = rv
                            }
                    renv =
                        traceWithdrawResolverEnv tr $
                            providerToWithdrawResolverEnv
                                tr
                                networkName
                                (goNetworkMagic g)
                                socket
                                backend
                er <- Withdraw.resolveWithdrawEnv renv ri
                env <- case er of
                    Left e ->
                        abortWithdraw
                            tr
                            ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceWithdrawEnv tr env
                result <-
                    case Withdraw.withdrawToTreasuryResult env answers of
                        Left we ->
                            abortWithdraw
                                tr
                                ( "translate: "
                                    <> T.pack
                                        ( show
                                            ( we
                                                :: Withdraw.WithdrawError
                                            )
                                        )
                                )
                        Right r -> pure r
                case result of
                    Withdraw.WithdrawNoRewards account ->
                        traceWith tr (WithdrawTrace.WweNoRewards account)
                    Withdraw.WithdrawIntentReady intent -> do
                        traceWith tr $
                            WithdrawTrace.WweValidityComputed
                                (Withdraw.weCurrentTip env)
                                (tiValidityUpperBoundSlot intent)
                        traceWith tr (WithdrawTrace.WweIntentReady wdOptsOut)
                        let bytes =
                                encodeSomeTreasuryIntent
                                    (SomeTreasuryIntent SWithdraw intent)
                        case wdOptsOut of
                            Nothing -> BSL.putStr bytes
                            Just fp -> BSL.writeFile fp bytes

{- | Open the log handle indicated by '--log' (or stderr if absent),
run the action, and close the handle on exit.
-}
withLogHandle :: Maybe FilePath -> (IO.Handle -> IO a) -> IO a
withLogHandle Nothing k = k stderr
withLogHandle (Just p) k =
    IO.withFile p IO.WriteMode $ \h -> do
        IO.hSetBuffering h IO.LineBuffering
        k h

-- | Trace and abort with exit code 3 (mirrors the previous error path).
abortTr :: Tracer IO WizardEvent -> Text -> IO a
abortTr tr msg = do
    traceWith tr (WeAborted msg)
    exitWith (ExitFailure 3)

-- | Trace and abort with exit code 3 for withdraw-wizard setup errors.
abortWithdraw
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent -> Text -> IO a
abortWithdraw tr msg = do
    traceWith tr (WithdrawTrace.WweAborted msg)
    exitWith (ExitFailure 3)

-- | Wrap a 'ResolverEnv' with tracing for each IO method.
traceResolverEnv
    :: Tracer IO WizardEvent
    -> ResolverEnv IO
    -> ResolverEnv IO
traceResolverEnv tr renv =
    ResolverEnv
        { reEnvQueryWalletUtxos = \addr -> do
            us <- reEnvQueryWalletUtxos renv addr
            traceWith tr (WeWalletUtxosQueried (length us))
            pure us
        , reEnvQueryTreasuryUtxos = \addr -> do
            us <- reEnvQueryTreasuryUtxos renv addr
            traceWith
                tr
                ( WeTreasuryUtxosQueried
                    (length us)
                    (sum (map (\(_, l, _) -> l) us))
                )
            pure us
        , reEnvCurrentTip = do
            t <- reEnvCurrentTip renv
            traceWith tr (WeTipRead t)
            pure t
        }

-- | Wrap a withdraw resolver env with tracing for each IO method.
traceWithdrawResolverEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Withdraw.WithdrawResolverEnv IO
    -> Withdraw.WithdrawResolverEnv IO
traceWithdrawResolverEnv tr renv =
    Withdraw.WithdrawResolverEnv
        { Withdraw.wreQueryWalletUtxos = \addr -> do
            us <- Withdraw.wreQueryWalletUtxos renv addr
            traceWith
                tr
                (WithdrawTrace.WweWalletUtxosQueried (length us))
            pure us
        , Withdraw.wreQueryRewardsLovelace = \account -> do
            rewards <-
                Withdraw.wreQueryRewardsLovelace renv account
            traceWith
                tr
                (WithdrawTrace.WweRewardsQueried account rewards)
            pure rewards
        , Withdraw.wreCurrentTip = do
            t <- Withdraw.wreCurrentTip renv
            traceWith tr (WithdrawTrace.WweTipRead t)
            pure t
        }

-- | Trace verifier outcome and on-chain owners for the requested scope.
traceRegistryView
    :: Tracer IO WizardEvent
    -> ScopeId
    -> RegistryView
    -> IO ()
traceRegistryView tr scope rv = do
    let refs = svRefs (mkScopeView scope rv)
    traceWith tr $
        WeRegistryVerified
            scope
            (trAddress refs)
            (trScriptHash refs)
            (rvRegistryPolicyId rv)
            (trPermissionsRewardAccount refs)
    let os = rvOwners rv
    traceWith tr $
        WeOwners
            (soCore os)
            (soOps os)
            (soNetworkCompliance os)
            (soMiddleware os)

-- | Trace verifier outcome for the requested withdraw scope.
traceWithdrawRegistryView
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> ScopeId
    -> Withdraw.RegistryView
    -> IO ()
traceWithdrawRegistryView tr scope rv =
    case Map.lookup scope (Withdraw.rvTreasuryByScope rv) of
        Just refs ->
            traceWith tr $
                WithdrawTrace.WweRegistryVerified
                    scope
                    (Withdraw.trAddress refs)
                    (Withdraw.trScriptHash refs)
                    (Withdraw.rvRegistryPolicyId rv)
        Nothing ->
            abortWithdraw
                tr
                "internal: missing scope in RegistryView (post-verify); please file a bug"

-- | Project a per-scope 'ScopeView' out of a 'RegistryView' for tracing.
mkScopeView :: ScopeId -> RegistryView -> ScopeView
mkScopeView scope rv =
    case Map.lookup scope (rvTreasuryByScope rv) of
        Just refs ->
            ScopeView
                { svScope = scope
                , svRefs = refs
                , svDefaultSigners = []
                }
        Nothing ->
            error "swap-wizard: missing scope in RegistryView (post-verify)"

{- | Trace post-resolve env data: NetworkConstants row,
selected wallet UTxO, selected treasury UTxOs + leftover.
-}
traceEnv :: Tracer IO WizardEvent -> WizardEnv -> IO ()
traceEnv tr env = do
    let nc = weNetworkConstants env
    traceWith tr $
        WeNetworkConstants
            (ncSwapOrderAddress nc)
            (ncUsdmPolicy nc)
            (ncUsdmToken nc)
            (ncSundaeProtocolFeeLovelace nc)
    let wsel = weWalletSelection env
    traceWith tr $
        WeWalletUtxoSelected (wsTxIn wsel)
    let tsel = weTreasurySelection env
    traceWith tr $
        WeTreasuryUtxosSelected
            (tsInputs tsel)
            (tsLeftoverLovelace tsel)

{- | Trace post-resolve withdraw env data: selected wallet UTxO,
reward account, and reward balance.
-}
traceWithdrawEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Withdraw.WithdrawEnv
    -> IO ()
traceWithdrawEnv tr env = do
    let wsel = Withdraw.weWalletSelection env
        rewardAccount = Withdraw.weTreasuryRewardAccount env
    traceWith tr $
        WithdrawTrace.WweWalletUtxoSelected
            (Withdraw.wsTxIn wsel)
    traceWith tr $
        WithdrawTrace.WweRewardAccountResolved rewardAccount
    traceWith tr $
        WithdrawTrace.WweRewardsQueried
            rewardAccount
            (Withdraw.weRewardsLovelace env)

{- | Adapter: project the lower-level 'Provider' interface
into the 'ResolverEnv' shape the wizard consumes.
-}
providerToResolverEnv :: Provider IO -> ResolverEnv IO
providerToResolverEnv p =
    ResolverEnv
        { reEnvQueryWalletUtxos = queryFlat p
        , reEnvQueryTreasuryUtxos = queryFlat p
        , reEnvCurrentTip = nowTip p
        }

-- | Adapter for the withdraw resolver.
providerToWithdrawResolverEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Text
    -> NetworkMagic
    -> FilePath
    -> Provider IO
    -> Withdraw.WithdrawResolverEnv IO
providerToWithdrawResolverEnv tr networkName magic socket p =
    Withdraw.WithdrawResolverEnv
        { Withdraw.wreQueryWalletUtxos = queryFlat p
        , Withdraw.wreQueryRewardsLovelace = \account -> do
            rewardAccount <- case parseRewardAccountForNetwork
                networkName
                account of
                Right value -> pure value
                Left e ->
                    abortWithdraw
                        tr
                        ( "resolve: reward account: "
                            <> T.pack e
                        )
            result <-
                queryStakeRewardsLovelace
                    magic
                    socket
                    rewardAccount
            case result of
                Right rewards -> pure rewards
                Left StakeRewardsEraMismatch ->
                    abortWithdraw
                        tr
                        "resolve: stake rewards query: node is not in Conway era"
        , Withdraw.wreCurrentTip = nowTip p
        }

queryFlat
    :: Provider IO
    -> Text
    -> IO [(Text, Integer, Bool)]
queryFlat p addrText = case parseAddr addrText of
    -- An unparseable address is a programmer/operator bug, not
    -- something the resolver should silently swallow into an
    -- empty UTxO list (which would surface downstream as a
    -- misleading 'ResolverEmptyWalletUtxos').
    Left e ->
        throwIO $
            userError
                ( "queryFlat: bech32 address: "
                    <> T.unpack addrText
                    <> ": "
                    <> e
                )
    Right a -> do
        utxos <- queryUTxOs p a
        pure (map summarise utxos)
  where
    summarise (txin, txout) =
        let MaryValue (Coin lov) (MultiAsset ma) =
                txout ^. valueTxOutL
        in  ( txInToText txin
            , lov
            , not (Map.null ma)
            )

nowTip :: Provider IO -> IO Word64
nowTip p = do
    nowSec <- getPOSIXTime
    let nowMs = round (realToFrac nowSec * (1000 :: Double))
    SlotNo s <- posixMsToSlot p nowMs
    pure s

-- ----------------------------------------------------
-- tx-build subcommand (unified intent dispatcher)
-- ----------------------------------------------------

{- | The unified @tx-build@ runner. Reads a
'SomeTreasuryIntent' from stdin or @--intent@, derives
the N2C handshake magic from the intent's @network@
field (single source of truth — no @--network@ flag
accepted on this subcommand), connects, queries the
required UTxOs, and dispatches via 'runFromIntent'.

The required-UTxO set comes from the intent's shared
blocks (wallet TxIn + scope's treasury inputs + four
deployed-at refs); these fields are the same across all
four action variants, so the computation works
unchanged for any 'SomeTreasuryIntent'.
-}
runTxBuild :: FilePath -> TxBuildOpts -> IO ()
runTxBuild socket TxBuildOpts{..} = do
    withLogHandle tboLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = buildEventTracer textTracer
        traceWith tr (TbeIntentSource tboIntentPath)
        parsed <- case tboIntentPath of
            Just p -> decodeTreasuryIntentFile p
            Nothing ->
                decodeTreasuryIntent <$> BSL.hGetContents IO.stdin
        some <- case parsed of
            Left e -> abortBuild tr ("intent JSON: " <> T.pack e)
            Right v -> pure v
        (actionName, netName) <-
            pure $ case some of
                SomeTreasuryIntent _sa intent ->
                    -- "SSwap" → "Swap"; user-readable.
                    ( T.pack
                        (drop 1 (show (tiSAction intent)))
                    , tiNetwork intent
                    )
        traceWith tr (TbeIntentParsed actionName netName)
        magic <- case netName of
            "mainnet" -> pure (NetworkMagic 764_824_073)
            "preprod" -> pure (NetworkMagic 1)
            "preview" -> pure (NetworkMagic 2)
            other ->
                abortBuild
                    tr
                    ( "unknown network in intent: " <> other
                    )
        traceWith tr (TbeConnect socket)
        required <- case requiredUtxos some of
            Left e ->
                abortBuild tr ("required UTxOs: " <> T.pack e)
            Right s -> pure s
        traceWith
            tr
            (TbeRequiredUtxos (Set.size required))
        -- Network handshake: probe the intent's magic against
        -- the socket; if it refuses, identify the socket's
        -- actual network by trying the two remaining known
        -- magics and emit a typed mismatch event before any
        -- balance or build work happens.
        ok <- probeNetworkMagic magic socket
        if ok
            then
                traceWith
                    tr
                    ( TbeNetworkOk
                        netName
                        (unNetworkMagic magic)
                    )
            else do
                socketMagic <-
                    findSocketMagic
                        (`probeNetworkMagic` socket)
                        netName
                traceWith
                    tr
                    ( TbeNetworkMismatch
                        netName
                        (unNetworkMagic magic)
                        socketMagic
                    )
                exitWith (ExitFailure 6)
        withLocalNodeBackend magic socket $ \backend -> do
            ctx <- liveContext backend required
            buildResult <- runFromIntentEither ctx some
            tbr <- case buildResult of
                Right result -> pure result
                Left err -> do
                    let message = renderTreasuryBuildError err
                    TIO.hPutStrLn stderr message
                    writeFailureReport
                        tr
                        tboReportPath
                        some
                        (treasuryBuildErrorCode err)
                        message
                    exitFailure
            let cborStrict = BSL.toStrict (tbrCborBytes tbr)
                hexed = B16.encode cborStrict
                Coin feeLov = tbrFeeLovelace tbr
                Coin tcLov = tbrTotalCollateralLovelace tbr
                failures =
                    [ (purpose, e)
                    | ScriptResult purpose (Left e) <-
                        tbrScriptResults tbr
                    ]
            traceWith
                tr
                ( TbeBuilt
                    (BS.length cborStrict)
                    feeLov
                    tcLov
                )
            traceWith
                tr
                ( TbeReevaluated
                    (length (tbrScriptResults tbr))
                    (length failures)
                )
            mapM_
                ( \(p, e) ->
                    traceWith
                        tr
                        ( TbeScriptFail
                            (T.pack (show p))
                            (T.pack e)
                        )
                )
                failures
            case (tboOutPath, tboReportPath == Just "-") of
                (Just p, _) -> BS.writeFile p hexed
                (Nothing, True) -> pure ()
                (Nothing, False) -> do
                    BS.putStr hexed
                    putStr "\n"
            traceWith tr (TbeWroteCbor tboOutPath)
            if null failures
                then do
                    traceWith tr TbeValidationOk
                    case tboReportPath of
                        Nothing -> pure ()
                        Just reportPath -> do
                            let report =
                                    buildTransactionReport
                                        (txBuildReportContext some magic)
                                        tbr
                                output =
                                    TxBuildOutput
                                        { txoIntent = some
                                        , txoResult =
                                            TxBuildOutputSuccess
                                                TxBuildSuccess
                                                    { tbsTxCbor =
                                                        txCborHexFromBytes
                                                            (tbrCborBytes tbr)
                                                    , tbsReport = report
                                                    }
                                        }
                            writeBuildReportOrExit
                                tr
                                reportPath
                                output
                else do
                    traceWith tr TbeValidationFailed
                    writeFailureReport
                        tr
                        tboReportPath
                        some
                        "validation-failed"
                        (renderValidationFailures failures)
                    exitFailure

writeFailureReport
    :: Tracer IO BuildEvent
    -> Maybe FilePath
    -> SomeTreasuryIntent
    -> Text
    -> Text
    -> IO ()
writeFailureReport _ Nothing _ _ _ =
    pure ()
writeFailureReport tr (Just reportPath) some code message =
    writeBuildReportOrExit
        tr
        reportPath
        TxBuildOutput
            { txoIntent = some
            , txoResult =
                TxBuildOutputFailure
                    BuildFailure
                        { bfCode = code
                        , bfMessage = message
                        }
            }

writeBuildReportOrExit
    :: Tracer IO BuildEvent
    -> FilePath
    -> TxBuildOutput
    -> IO ()
writeBuildReportOrExit tr "-" output = do
    BSL.putStr (encodeBuildOutput output)
    traceWith tr (TbeWroteReport "-")
writeBuildReportOrExit tr reportPath output = do
    result <-
        writeReportArtifact
            tr
            reportPath
            (encodeBuildOutput output)
    case result of
        Right () -> pure ()
        Left{} -> exitWith (ExitFailure 4)

renderValidationFailures :: [(a, String)] -> Text
renderValidationFailures failures =
    T.intercalate
        "; "
        [ T.pack reason
        | (_, reason) <- failures
        ]

txBuildReportContext
    :: SomeTreasuryIntent -> NetworkMagic -> ReportContext
txBuildReportContext (SomeTreasuryIntent _ intent) magic =
    ReportContext
        { rcNetwork = tiNetwork intent
        , rcSocketNetworkMagic =
            fromIntegral (unNetworkMagic magic)
        , rcSelectedScopeOwner =
            case tiSigners intent of
                owner : _ ->
                    Just (owner, sjId (tiScope intent))
                [] -> Nothing
        , rcExtraSigners =
            drop 1 (tiSigners intent)
        , rcIntentRequiredSigners = []
        }

-- | Trace and abort with exit code 3 (parse / setup error).
abortBuild :: Tracer IO BuildEvent -> Text -> IO a
abortBuild tr msg = do
    traceWith tr (TbeAborted msg)
    exitWith (ExitFailure 3)

{- | Compute the set of UTxOs the build needs to query.
The shared blocks (wallet, scope.treasuryUtxos, four
deployed-at refs) are the same shape across all four
action variants, so this works for any
'SomeTreasuryIntent'.
-}
requiredUtxos
    :: SomeTreasuryIntent -> Either String (Set.Set TxIn)
requiredUtxos (SomeTreasuryIntent _sa intent) = do
    let wallet = tiWallet intent
        scope = tiScope intent
    walletTxIn <- parseTxIn (wjTxIn wallet)
    extraWalletTxIns <-
        traverse parseTxIn (wjExtraTxIns wallet)
    treasuryUtxos <-
        traverse parseTxIn (sjTreasuryUtxos scope)
    scopesRef <- parseTxIn (sjScopesDeployedAt scope)
    permissionsRef <-
        parseTxIn (sjPermissionsDeployedAt scope)
    treasuryRef <- parseTxIn (sjTreasuryDeployedAt scope)
    registryRef <- parseTxIn (sjRegistryDeployedAt scope)
    Right $
        Set.fromList $
            walletTxIn
                : extraWalletTxIns
                ++ treasuryUtxos
                ++ [ scopesRef
                   , permissionsRef
                   , treasuryRef
                   , registryRef
                   ]
