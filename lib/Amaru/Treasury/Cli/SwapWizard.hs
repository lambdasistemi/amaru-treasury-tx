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
    , runWizard
    ) where

import Control.Applicative ((<|>))
import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
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

import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.Cli.SwapCommon
    ( abortTr
    , currentIso8601
    , providerToResolverEnv
    , resolveSwapQuoteObservation
    , traceEnv
    , traceRegistryView
    , traceResolverEnv
    )
import Amaru.Treasury.Cli.SwapOptions
    ( SwapQuoteQuoteArg (..)
    , quoteP
    , slippageReader
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
    ( RationaleAnswers (..)
    , ResolverError (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WizardEnv (..)
    , WizardError
    , registryViewFromVerified
    , renderWalletShortfall
    , resolveWizardEnv
    , wizardToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    )

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
    , wOptsChunkSpec :: !ChunkSpec
    -- ^ how to split the amount into chunks
    , wOptsRate :: !WizardRate
    -- ^ minimum acceptable USDM per ADA, either explicit or quote-derived
    , wOptsValidityHours :: !(Maybe Word16)
    , wOptsDescription :: !Text
    , wOptsJustification :: !Text
    , wOptsDestinationLabel :: !Text
    , wOptsEvent :: !(Maybe Text)
    , wOptsLabel :: !(Maybe Text)
    , wOptsSigners :: ![Text]
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

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

positiveSplit :: ReadM Int
positiveSplit = eitherReader $ \s -> case reads s of
    [(n, "")]
        | n >= 1 -> Right n
        | otherwise -> Left "--split must be a positive integer (>= 1)"
    _ -> Left ("--split: not an integer: " <> s)

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

usdmToLovelace :: Double -> Double -> Integer
usdmToLovelace usdm rate =
    round (toRational usdm * 1_000_000 / toRational rate)

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

runWizard :: GlobalOpts -> WizardOpts -> IO ()
runWizard g WizardOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle wOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = eventTracer textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortTr tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith tr (WeNetwork networkName (fromIntegral magic))
        traceWith tr (WeMetadata wOptsMetadataPath)

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
                    , wqValidityHours =
                        wOptsValidityHours
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
                            , riValidityHours =
                                wOptsValidityHours
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
                    WeUpperBoundResolved
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
