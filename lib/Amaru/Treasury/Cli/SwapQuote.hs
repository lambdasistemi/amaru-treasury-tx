{-# LANGUAGE OverloadedStrings #-}

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
    , swapQuotePaths
    , deriveSwapQuotePlan
    , decideSwapQuoteRun
    ) where

import Control.Applicative ((<|>))
import Data.Char (isAsciiUpper)
import Data.Text (Text)
import Data.Text qualified as T
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
import System.FilePath ((</>))

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
    , parseSlippageBps
    )
import Amaru.Treasury.Tx.SwapQuote.Source
    ( QuoteSource
    , parseQuoteSourceName
    , renderQuoteSourceError
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RationaleAnswers (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    )

data SwapQuoteQuoteArg
    = SwapQuoteOverride !QuoteObservation
    | SwapQuoteSource !QuoteSource
    deriving (Eq, Show)

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

quoteP :: Parser SwapQuoteQuoteArg
quoteP =
    adaUsdP <|> adaUsdmP <|> priceSourceP
  where
    adaUsdP =
        SwapQuoteOverride
            <$> option
                (quoteOverrideReader AdaUsdOverride)
                ( long "ada-usd"
                    <> metavar "DECIMAL"
                    <> help "Explicit ADA/USD quote override"
                )
    adaUsdmP =
        SwapQuoteOverride
            <$> option
                (quoteOverrideReader AdaUsdmOverride)
                ( long "ada-usdm"
                    <> metavar "DECIMAL"
                    <> help "Explicit ADA/USDM quote override"
                )
    priceSourceP =
        SwapQuoteSource
            <$> option
                priceSourceReader
                ( long "price-source"
                    <> metavar "SOURCE"
                    <> help "Named quote source, currently coingecko-ada-usd"
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

quoteOverrideReader :: (Text -> QuoteInput) -> ReadM QuoteObservation
quoteOverrideReader mkInput =
    eitherReader $ \raw ->
        case parseQuoteInput (mkInput (T.pack raw)) of
            Right observation ->
                Right observation
            Left err ->
                Left (show err)

priceSourceReader :: ReadM QuoteSource
priceSourceReader =
    eitherReader $ \raw ->
        case parseQuoteSourceName (T.pack raw) of
            Right source ->
                Right source
            Left err ->
                Left (T.unpack (renderQuoteSourceError err))

slippageReader :: ReadM SlippageBps
slippageReader =
    eitherReader $ \raw ->
        case parseSlippageBps (Just (T.pack raw)) of
            Right slippage ->
                Right slippage
            Left err ->
                Left (show err)

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
