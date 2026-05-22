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
    , validateWizardInputControl
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
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    )
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

data WizardRateParameters = WizardRateParameters
    { wrpRateNumerator :: !Integer
    , wrpRateDenominator :: !Integer
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

resolveWizardSwapParameters
    :: Tracer IO WizardEvent
    -> Double
    -> ChunkSpec
    -> WizardRate
    -> IO WizardSwapParameters
resolveWizardSwapParameters tr usdm chunkSpec = \case
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
    WizardOverrideRate adaUsdm slippage -> do
        let observation =
                SQ.QuoteObservation
                    { SQ.qoPair = SQ.AdaUsdm
                    , SQ.qoQuote = toRational adaUsdm
                    , SQ.qoProvenance = SQ.OperatorOverride
                    }
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

resolveWizardRateParameters
    :: Tracer IO WizardEvent
    -> WizardRate
    -> IO WizardRateParameters
resolveWizardRateParameters tr = \case
    WizardMinRate minRate ->
        let (rateNum, rateDen) = rateToFraction minRate
        in  pure
                WizardRateParameters
                    { wrpRateNumerator = rateNum
                    , wrpRateDenominator = rateDen
                    }
    WizardOverrideRate adaUsdm slippage -> do
        let observation =
                SQ.QuoteObservation
                    { SQ.qoPair = SQ.AdaUsdm
                    , SQ.qoQuote = toRational adaUsdm
                    , SQ.qoProvenance = SQ.OperatorOverride
                    }
        derived <-
            case SQ.deriveSwapParameters
                observation
                slippage
                SQ.SwapQuoteRequest
                    { SQ.sqrRequestedUsdm = 1
                    , SQ.sqrChunk = SQ.SplitInto 1
                    } of
                Right value ->
                    pure value
                Left err ->
                    abortTr tr ("derive swap rate: " <> T.pack (show err))
        pure
            WizardRateParameters
                { wrpRateNumerator = SQ.dspRateNumerator derived
                , wrpRateDenominator = SQ.dspRateDenominator derived
                }

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

runWizard :: GlobalOpts -> WizardOpts -> IO ()
runWizard g opts@WizardOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle wOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = eventTracer textTracer
        case validateWizardInputControl opts of
            Right () -> pure ()
            Left ce ->
                abortTr tr (renderInputControlError ce)
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortTr tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith tr (WeNetwork networkName (fromIntegral magic))
        traceWith tr (WeMetadata wOptsMetadataPath)

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
                let renv =
                        traceResolverEnv tr $
                            providerToResolverEnv backend
                (env, params) <-
                    case wOptsOrder of
                        FixedUsdm usdm chunkSpec -> do
                            params <-
                                resolveWizardSwapParameters
                                    tr
                                    usdm
                                    chunkSpec
                                    wOptsRate
                            let ri =
                                    ResolverInput
                                        { riNetwork = networkName
                                        , riWalletAddrBech32 =
                                            wOptsWalletAddr
                                        , riScope = wOptsScope
                                        , riAmountLovelace =
                                            wspAmountLovelace params
                                        , riChunkSizeLovelace =
                                            wspChunkSizeLovelace params
                                        , riRegistry = rv
                                        , riValidityHours =
                                            wOptsValidityHours
                                        }
                            er <-
                                resolveWizardEnvIC
                                    renv
                                    wOptsExcludeSet
                                    wOptsForcedSet
                                    ri
                            env <- case er of
                                Left
                                    ( ResolverWalletShortfall
                                            avail
                                            required
                                        ) ->
                                        abortTr
                                            tr
                                            ( renderWalletShortfall
                                                ri
                                                avail
                                                required
                                            )
                                Left
                                    ( ResolverWalletShortfallWithExcludes
                                            avail
                                            required
                                            refs
                                        ) ->
                                        abortTr
                                            tr
                                            ( renderWalletShortfallWithExcludes
                                                ( renderWalletShortfall
                                                    ri
                                                    avail
                                                    required
                                                )
                                                refs
                                            )
                                Left
                                    ( ResolverExtraTxInNotOnWallet
                                            refs
                                        ) ->
                                        abortTr
                                            tr
                                            ( renderExtraTxInNotOnWallet
                                                refs
                                            )
                                Left e ->
                                    abortTr
                                        tr
                                        ("resolve: " <> T.pack (show e))
                                Right (e, outcome) -> do
                                    emitExclusionLog textTracer outcome
                                    pure e
                            pure (env, params)
                        AllAda split -> do
                            rateParams <-
                                resolveWizardRateParameters tr wOptsRate
                            let rai =
                                    ResolverAllAdaInput
                                        { raiNetwork = networkName
                                        , raiWalletAddrBech32 =
                                            wOptsWalletAddr
                                        , raiScope = wOptsScope
                                        , raiSplit = split
                                        , raiRateNumerator =
                                            wrpRateNumerator rateParams
                                        , raiRateDenominator =
                                            wrpRateDenominator rateParams
                                        , raiRegistry = rv
                                        , raiValidityHours =
                                            wOptsValidityHours
                                        }
                            er <-
                                resolveWizardEnvAllAdaIC
                                    renv
                                    wOptsExcludeSet
                                    wOptsForcedSet
                                    rai
                            (env, plan) <- case er of
                                Left
                                    ( ResolverExtraTxInNotOnWallet
                                            refs
                                        ) ->
                                        abortTr
                                            tr
                                            ( renderExtraTxInNotOnWallet
                                                refs
                                            )
                                Left
                                    ( ResolverWalletShortfallWithExcludes
                                            avail
                                            required
                                            refs
                                        ) ->
                                        abortTr
                                            tr
                                            ( renderWalletShortfallWithExcludes
                                                ( "wallet shortfall available="
                                                    <> T.pack
                                                        (show avail)
                                                    <> " required="
                                                    <> T.pack
                                                        (show required)
                                                )
                                                refs
                                            )
                                Left e ->
                                    abortTr
                                        tr
                                        ("resolve: " <> T.pack (show e))
                                Right (e, plan', outcome) -> do
                                    emitExclusionLog textTracer outcome
                                    pure (e, plan')
                            traceAllAdaPlan tr plan split
                            pure
                                ( env
                                , WizardSwapParameters
                                    { wspAmountLovelace =
                                        aapAmountLovelace plan
                                    , wspChunkSizeLovelace =
                                        aapChunkSizeLovelace plan
                                    , wspRateNumerator =
                                        aapRateNumerator plan
                                    , wspRateDenominator =
                                        aapRateDenominator plan
                                    }
                                )
                traceEnv tr env
                let answers =
                        SwapWizardQ
                            { wqScope = wOptsScope
                            , wqAmountLovelace =
                                wspAmountLovelace params
                            , wqChunkSizeLovelace =
                                wspChunkSizeLovelace params
                            , wqRateNumerator =
                                wspRateNumerator params
                            , wqRateDenominator =
                                wspRateDenominator params
                            , wqValidityHours =
                                wOptsValidityHours
                            , wqRationale =
                                RationaleAnswers
                                    { raDescription =
                                        wOptsDescription
                                    , raJustification =
                                        wOptsJustification
                                    , raDestinationLabel =
                                        wOptsDestinationLabel
                                    , raEvent = wOptsEvent
                                    , raLabel = wOptsLabel
                                    }
                            , wqExtraSigners = wOptsSigners
                            }
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

{- | Emit one log line per excluded ref that matched a
candidate pool, in exclusion-set input order. Refs that
did not match any pool ('icoInert') are still logged so
the operator sees their @--exclude-utxo@ was applied.
-}
emitExclusionLog
    :: Tracer IO Text -> InputControlOutcome -> IO ()
emitExclusionLog textTracer outcome = do
    mapM_
        ( traceWith textTracer
            . uncurry renderExclusionLogLine
        )
        (icoHits outcome)
    mapM_
        ( \ref ->
            traceWith
                textTracer
                ( "swap-wizard: excluded utxo "
                    <> outRefText ref
                    <> " (operator-supplied) [absent]"
                )
        )
        (icoInert outcome)

{- | Render the FR-009 "extra input not found on wallet"
error, naming every offending outref the operator
supplied via @--extra-tx-in@.
-}
renderExtraTxInNotOnWallet :: [OutRef] -> Text
renderExtraTxInNotOnWallet refs =
    "swap-wizard: extra input not found on wallet: "
        <> T.intercalate ", " (map outRefText refs)
