{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.SwapQuote
Description : Parser for quote-derived swap preparation
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts (..)
    , SwapQuoteQuoteArg (..)
    , SwapQuotePaths (..)
    , SwapQuotePlan (..)
    , SwapQuoteRunDecision (..)
    , swapQuoteOptsP
    , quoteP
    , slippageReader
    , swapQuotePaths
    , deriveSwapQuotePlan
    , decideSwapQuoteRun
    , runSwapQuote
    ) where

import Control.Applicative ((<|>))
import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAsciiUpper)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word8)
import Options.Applicative
    ( Parser
    , ReadM
    , eitherReader
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

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
import Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , runTxBuild
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
    , scopeText
    )
import Amaru.Treasury.Tx.SwapQuote
    ( AffordabilityFailure (..)
    , AffordabilitySummary
    , DerivedSwapParameters (..)
    , QuoteInput (..)
    , QuoteObservation (..)
    , QuoteProvenance (..)
    , SlippageBps
    , SwapQuoteAudit (..)
    , SwapQuoteAuditRequest (..)
    , SwapQuoteOutputs (..)
    , SwapQuoteRequest (..)
    , SwapQuoteRequestChunk (..)
    , SwapQuoteStatus (..)
    , checkAffordability
    , deriveSwapParameters
    , parseQuoteInput
    , renderAffordabilityFailure
    , writeSwapQuoteAudit
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants (..)
    , RationaleAnswers (..)
    , ResolverError (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , TreasurySelection (..)
    , WizardEnv (..)
    , WizardError
    , networkConstants
    , registryViewFromVerified
    , renderWalletShortfall
    , resolveWizardEnv
    , wizardToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    )

data SwapQuoteOpts = SwapQuoteOpts
    { sqoWalletAddr :: !Text
    , sqoMetadataPath :: !FilePath
    , sqoOutDir :: !FilePath
    , sqoScope :: !ScopeId
    , sqoRequestedUsdm :: !Text
    , sqoChunk :: !SwapQuoteRequestChunk
    , sqoQuote :: !SwapQuoteQuoteArg
    , sqoSlippageBps :: !SlippageBps
    , sqoValidityHours :: !Word8
    , sqoDescription :: !Text
    , sqoJustification :: !Text
    , sqoDestinationLabel :: !Text
    , sqoEvent :: !(Maybe Text)
    , sqoLabel :: !(Maybe Text)
    , sqoSigners :: ![Text]
    }
    deriving (Eq, Show)

data SwapQuotePaths = SwapQuotePaths
    { sqpIntentJson :: !FilePath
    , sqpUnsignedCborHex :: !FilePath
    , sqpParamsJson :: !FilePath
    , sqpWizardLog :: !FilePath
    , sqpBuildLog :: !FilePath
    }
    deriving (Eq, Show)

data SwapQuotePlan = SwapQuotePlan
    { sqpObservation :: !QuoteObservation
    , sqpDerived :: !DerivedSwapParameters
    , sqpRequest :: !SwapQuoteRequest
    , sqpAnswers :: !SwapWizardQ
    , sqpResolverInput :: !(ResolverInput -> ResolverInput)
    , sqpAuditRequest :: !SwapQuoteAuditRequest
    , sqpOutputs :: !SwapQuoteOutputs
    , sqpPaths :: !SwapQuotePaths
    }

instance Show SwapQuotePlan where
    show plan =
        "SwapQuotePlan "
            <> show
                ( sqpObservation plan
                , sqpDerived plan
                , sqpRequest plan
                , sqpAnswers plan
                , sqpAuditRequest plan
                , sqpOutputs plan
                , sqpPaths plan
                )

data SwapQuoteRunDecision
    = SwapQuoteRunAllowed !AffordabilitySummary !SwapQuoteAudit
    | SwapQuoteRunBlocked !AffordabilityFailure !SwapQuoteAudit
    deriving (Eq, Show)

swapQuoteOptsP :: Parser SwapQuoteOpts
swapQuoteOptsP =
    SwapQuoteOpts
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
        <*> strOption
            ( long "out-dir"
                <> metavar "PATH"
                <> help "Directory for intent.json, swap.cbor.hex, params.json, and logs"
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> strOption
            ( long "usdm"
                <> metavar "USDM"
                <> help "Target USDM amount"
            )
        <*> chunkP
        <*> quoteP
        <*> option
            slippageReader
            ( long "slippage-bps"
                <> metavar "INT"
                <> help "Explicit slippage policy in basis points; 0 <= INT < 10000"
            )
        <*> option
            autoWord8
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
                    <> help "Rationale event override"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help "Rationale label override"
                )
            )
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> long "signer"
                    <> metavar "SCOPE|HEX"
                    <> help "Repeat for each extra signer"
                )
            )

chunkP :: Parser SwapQuoteRequestChunk
chunkP =
    splitP <|> chunkUsdmP
  where
    splitP =
        SplitInto
            <$> option
                positiveSplit
                ( long "split"
                    <> metavar "INT"
                    <> help "Split the order into N equal chunks"
                )
    chunkUsdmP =
        ChunkUsdm
            <$> option
                positiveDecimalReader
                ( long "chunk-usdm"
                    <> metavar "USDM"
                    <> help "Per-chunk USDM size"
                )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLowerAscii

positiveSplit :: ReadM Int
positiveSplit =
    eitherReader $ \raw ->
        case reads raw of
            [(n, "")]
                | n >= (1 :: Int) ->
                    Right n
            _ ->
                Left "--split must be a positive integer"

positiveDecimalReader :: ReadM Rational
positiveDecimalReader =
    eitherReader $ \raw ->
        case parseQuoteInput (AdaUsdOverride (T.pack raw)) of
            Right observation ->
                Right (qoQuote observation)
            Left err ->
                Left (show err)

autoWord8 :: ReadM Word8
autoWord8 =
    eitherReader $ \raw ->
        case reads raw of
            [(n, "")]
                | n >= (0 :: Word8) ->
                    Right n
            _ ->
                Left ("not a Word8: " <> raw)

toLowerAscii :: Char -> Char
toLowerAscii c
    | isAsciiUpper c =
        toEnum (fromEnum c + 32)
    | otherwise =
        c

swapQuotePaths :: FilePath -> SwapQuotePaths
swapQuotePaths outDir =
    SwapQuotePaths
        { sqpIntentJson = outDir </> "intent.json"
        , sqpUnsignedCborHex = outDir </> "swap.cbor.hex"
        , sqpParamsJson = outDir </> "params.json"
        , sqpWizardLog = outDir </> "wizard.log"
        , sqpBuildLog = outDir </> "build.log"
        }

deriveSwapQuotePlan
    :: Text
    -> SwapQuoteOpts
    -> QuoteObservation
    -> Either String SwapQuotePlan
deriveSwapQuotePlan network opts observation = do
    requestedUsdm <-
        parsePositiveDecimalText "usdm" (sqoRequestedUsdm opts)
    let request =
            SwapQuoteRequest
                { sqrRequestedUsdm = requestedUsdm
                , sqrChunk = sqoChunk opts
                }
    derived <-
        case deriveSwapParameters observation (sqoSlippageBps opts) request of
            Right value ->
                Right value
            Left err ->
                Left ("derive swap parameters: " <> show err)
    let paths = swapQuotePaths (sqoOutDir opts)
        answers =
            SwapWizardQ
                { wqScope = sqoScope opts
                , wqAmountLovelace = dspAmountLovelace derived
                , wqChunkSizeLovelace = dspChunkSizeLovelace derived
                , wqRateNumerator = dspRateNumerator derived
                , wqRateDenominator = dspRateDenominator derived
                , wqValidityHours = sqoValidityHours opts
                , wqRationale =
                    RationaleAnswers
                        { raDescription = sqoDescription opts
                        , raJustification = sqoJustification opts
                        , raDestinationLabel = sqoDestinationLabel opts
                        , raEvent = sqoEvent opts
                        , raLabel = sqoLabel opts
                        }
                , wqExtraSigners = sqoSigners opts
                }
        outputs =
            SwapQuoteOutputs
                { sqoIntentJson = sqpIntentJson paths
                , sqoUnsignedCborHex = Just (sqpUnsignedCborHex paths)
                , sqoWizardLog = sqpWizardLog paths
                , sqoBuildLog = Just (sqpBuildLog paths)
                }
    Right
        SwapQuotePlan
            { sqpObservation = observation
            , sqpDerived = derived
            , sqpRequest = request
            , sqpAnswers = answers
            , sqpResolverInput =
                \ri ->
                    ri
                        { riNetwork = network
                        , riWalletAddrBech32 = sqoWalletAddr opts
                        , riScope = sqoScope opts
                        , riAmountLovelace = dspAmountLovelace derived
                        , riChunkSizeLovelace = dspChunkSizeLovelace derived
                        }
            , sqpAuditRequest =
                SwapQuoteAuditRequest
                    { sqarNetwork = network
                    , sqarScope = scopeText (sqoScope opts)
                    , sqarRequestedUsdm = requestedUsdm
                    , sqarChunk = sqoChunk opts
                    , sqarValidityHours = toInteger (sqoValidityHours opts)
                    , sqarExtraSigners = sqoSigners opts
                    }
            , sqpOutputs = outputs
            , sqpPaths = paths
            }

decideSwapQuoteRun
    :: SwapQuotePlan
    -> Integer
    -- ^ Extra lovelace funded by the treasury for each generated chunk.
    -> Integer
    -- ^ Available treasury lovelace.
    -> SwapQuoteRunDecision
decideSwapQuoteRun plan extraPerChunk available =
    case checkAffordability (sqpDerived plan) extraPerChunk available of
        Right summary ->
            SwapQuoteRunAllowed
                summary
                (auditWith SwapQuoteBuilt (sqpOutputs plan) summary)
        Left failure@(Unaffordable summary) ->
            let failedOutputs =
                    (sqpOutputs plan)
                        { sqoUnsignedCborHex = Nothing
                        , sqoBuildLog = Nothing
                        }
            in  SwapQuoteRunBlocked
                    failure
                    (auditWith SwapQuoteAffordabilityFailed failedOutputs summary)
  where
    auditWith status outputs summary =
        SwapQuoteAudit
            { sqaStatus = status
            , sqaObservedAt = observationTime (sqpObservation plan)
            , sqaDerived = sqpDerived plan
            , sqaRequest = sqpAuditRequest plan
            , sqaAffordability = summary
            , sqaOutputs = outputs
            }

observationTime :: QuoteObservation -> Text
observationTime observation =
    case qoProvenance observation of
        QuoteSourceProvenance _ fetchedAt _ ->
            fetchedAt
        OperatorOverride ->
            ""

parsePositiveDecimalText :: String -> Text -> Either String Rational
parsePositiveDecimalText label raw =
    case parseQuoteInput (AdaUsdOverride raw) of
        Right observation ->
            Right (qoQuote observation)
        Left err ->
            Left (label <> ": " <> show err)

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
                        runTxBuild
                            socket
                            TxBuildOpts
                                { tboIntentPath =
                                    Just (sqpIntentJson paths)
                                , tboOutPath =
                                    Just (sqpUnsignedCborHex paths)
                                , tboLog = Just (sqpBuildLog paths)
                                , tboReportPath = Nothing
                                }
                        writeSwapQuoteAudit
                            (sqpParamsJson paths)
                            (stampSwapQuoteAudit observedAt audit)

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
