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

* @swap [--intent path\/to\/intent.json] [--out path\/swap.cbor] [--log path\/swap.log]@ —
  builds the SundaeSwap order tx for a treasury scope. With no
  @--intent@, reads the intent.json from stdin so
  @swap-wizard ... | swap@ pipes cleanly.
  See [@docs\/swap.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/docs/swap.md).
* @swap-wizard --network <preprod|mainnet> --wallet-addr ... --metadata path\/to\/metadata.json --scope ... --usdm N.NN --split N --min-rate N.NN --validity-hours N --description ... --justification ... --destination-label ... [--extra-signer SCOPE|HEX]... [--out path\/intent.json] [--log path\/wizard.log]@
  produces a swap @intent.json@ from a typed questionnaire.
  See [@specs\/002-swap-wizard\/quickstart.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/quickstart.md).
-}
module Main (main) where

import Control.Applicative ((<|>))
import Control.Exception (throwIO)
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
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64, Word8)
import Lens.Micro ((^.))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Data.Set qualified as Set

import Cardano.Ledger.Api.Tx.Out (valueTxOutL)

import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.ChainContext (liveContext)
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseTxIn
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.TreasuryBuild
    ( ScriptResult (..)
    , TreasuryBuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.TreasuryBuild.Trace
    ( BuildEvent (..)
    , buildEventTracer
    )
import Amaru.Treasury.Tx.Swap (SwapIntent (..))
import Amaru.Treasury.Tx.Swap.Trace
    ( SwapEvent (..)
    , swapEventTracer
    )
import Amaru.Treasury.Tx.SwapBuild
    ( SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )
import Amaru.Treasury.Tx.SwapIntentJSON
    ( SwapInputs (..)
    , SwapIntentJSON (..)
    , TranslatedIntent (..)
    , decodeSwapIntent
    , decodeSwapIntentFile
    , parseAddr
    , translateIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants (..)
    , RationaleAnswers (..)
    , RegistryView (..)
    , ResolverEnv (..)
    , ResolverInput (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , SwapWizardQ (..)
    , TreasuryRefs (..)
    , TreasurySelection (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , WizardError
    , encodeIntentJSON
    , registryViewFromVerified
    , resolveWizardEnv
    , txInToText
    , wizardToIntentJSON
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    )
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
    = CmdSwap SwapOpts
    | CmdSwapWizard WizardOpts
    | CmdTxBuild TxBuildOpts

data SwapOpts = SwapOpts
    { soIntentPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = read intent.json from stdin (so
    --   @swap-wizard ... | swap@ pipes cleanly).
    , soOutPath :: !(Maybe FilePath)
    -- ^ where to write the hex CBOR. 'Nothing' = stdout.
    , soLog :: !(Maybe FilePath)
    -- ^ where to send 'SwapEvent' lines. 'Nothing' = stderr.
    }

{- | Flags for the unified @tx-build@ subcommand. The
network is read from the intent's @network@ field, not
from any CLI flag — the intent is the single source of
truth (research §R3 of feature 005).
-}
data TxBuildOpts = TxBuildOpts
    { tboIntentPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = read intent.json from stdin
    , tboOutPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = stdout
    , tboLog :: !(Maybe FilePath)
    -- ^ 'Nothing' = stderr
    }

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
    , wOptsMinRate :: !Double
    -- ^ minimum acceptable USDM per ADA, decimal
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

swapOptsP :: Parser SwapOpts
swapOptsP =
    SwapOpts
        <$> optional
            ( strOption
                ( long "intent"
                    <> short 'i'
                    <> metavar "PATH"
                    <> help
                        "Path to the swap-intent JSON (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
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

txBuildOptsP :: Parser TxBuildOpts
txBuildOptsP =
    TxBuildOpts
        <$> optional
            ( strOption
                ( long "intent"
                    <> short 'i'
                    <> metavar "PATH"
                    <> help
                        "Path to the unified intent.json (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
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

cmdP :: Parser Cmd
cmdP =
    hsubparser
        ( command
            "swap"
            ( info
                (CmdSwap <$> swapOptsP)
                ( progDesc
                    "Build a SundaeSwap treasury swap (ADA→USDM) [DEPRECATED — use tx-build]"
                )
            )
            <> command
                "tx-build"
                ( info
                    (CmdTxBuild <$> txBuildOptsP)
                    ( progDesc
                        "Build any treasury transaction from a unified intent.json"
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
        <*> option
            auto
            ( long "min-rate"
                <> metavar "USDM_PER_ADA"
                <> help "Min acceptable rate, e.g. 0.245"
            )
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
    socket <- resolveSocket (goSocketPath g)
    case c of
        CmdSwap so ->
            runSwap g{goSocketPath = Just socket} so
        CmdSwapWizard wo ->
            runWizard g{goSocketPath = Just socket} wo
        CmdTxBuild to ->
            runTxBuild socket to

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

runSwap :: GlobalOpts -> SwapOpts -> IO ()
runSwap g SwapOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle soLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = swapEventTracer textTracer
        traceWith tr (SeIntentSource soIntentPath)
        parsed <- case soIntentPath of
            Just p -> decodeSwapIntentFile p
            Nothing ->
                decodeSwapIntent <$> BSL.hGetContents IO.stdin
        sij <- case parsed of
            Left e -> abortSwap tr ("intent JSON: " <> T.pack e)
            Right v -> pure v
        TranslatedIntent{..} <- case translateIntent sij of
            Left e ->
                abortSwap
                    tr
                    ("intent translation: " <> T.pack e)
            Right v -> pure v
        traceWith tr (SeConnect socket)
        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                let intent = tiSwapIntent
                    allRequired =
                        Set.fromList $
                            tiWalletTxIn
                                : siTreasuryUtxos intent
                                ++ [ siScopesDeployedAt intent
                                   , siPermissionsDeployedAt intent
                                   , siTreasuryDeployedAt intent
                                   , siRegistryDeployedAt intent
                                   ]
                traceWith
                    tr
                    (SeRequiredUtxos (Set.size allRequired))
                ctx <- liveContext backend allRequired
                let inputs =
                        SwapBuildInputs
                            { sbiIntent = intent
                            , sbiRationale = tiRationale
                            , sbiWalletTxIn = tiWalletTxIn
                            , sbiWalletAddr = tiWalletAddr
                            }
                SwapBuildResult{..} <- runSwapBuild ctx inputs
                let cborStrict = BSL.toStrict sbrCborBytes
                    hexed = B16.encode cborStrict
                    Coin feeLov = sbrFeeLovelace
                    Coin tcLov = sbrTotalCollateralLovelace
                    failures =
                        [ (purpose, e)
                        | ScriptResult purpose (Left e) <-
                            sbrScriptResults
                        ]
                traceWith
                    tr
                    ( SeBuilt
                        (BS.length cborStrict)
                        feeLov
                        tcLov
                    )
                traceWith
                    tr
                    ( SeReevaluated
                        (length sbrScriptResults)
                        (length failures)
                    )
                mapM_
                    ( \(p, e) ->
                        traceWith
                            tr
                            ( SeScriptFail
                                (T.pack (show p))
                                (T.pack e)
                            )
                    )
                    failures
                case soOutPath of
                    Just p -> BS.writeFile p hexed
                    Nothing -> do
                        BS.putStr hexed
                        putStr "\n"
                traceWith tr (SeWroteCbor soOutPath)
                if null failures
                    then traceWith tr SeValidationOk
                    else do
                        traceWith tr SeValidationFailed
                        exitFailure

{- | Trace and abort with exit code 1 (mirrors the previous
'throwIO . userError' path but routes the message through the
typed tracer instead of escaping as an IOException).
-}
abortSwap :: Tracer IO SwapEvent -> Text -> IO a
abortSwap tr msg = do
    traceWith tr (SeAborted msg)
    exitWith (ExitFailure 1)

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
        let amountLov = usdmToLovelace wOptsUsdm wOptsMinRate
            chunkSize = case wOptsChunkSpec of
                -- 'positiveSplit' rejects N < 1 at parse time.
                SplitCount n -> amountLov `div` toInteger n
                ChunkUsdm x -> usdmToLovelace x wOptsMinRate
            (rateNum, rateDen) = rateToFraction wOptsMinRate
            answers =
                SwapWizardQ
                    { wqScope = wOptsScope
                    , wqAmountLovelace = amountLov
                    , wqChunkSizeLovelace = chunkSize
                    , wqRateNumerator = rateNum
                    , wqRateDenominator = rateDen
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
                            , riRegistry = rv
                            }
                let renv =
                        traceResolverEnv tr $
                            providerToResolverEnv backend
                er <- resolveWizardEnv renv ri
                env <- case er of
                    Left e ->
                        abortTr tr ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceEnv tr env
                intent <- case wizardToIntentJSON env answers of
                    Left we ->
                        abortTr
                            tr
                            ("translate: " <> T.pack (show (we :: WizardError)))
                    Right i -> pure i
                let total = swAmountLovelace (sijSwap intent)
                    cs = swChunkSizeLovelace (sijSwap intent)
                    full = total `div` cs
                    rem' = total `mod` cs
                traceWith tr $
                    WeValidityComputed
                        (weCurrentTip env)
                        (sijValidityUpperBoundSlot intent)
                traceWith tr $
                    WeChunksComputed total cs (fromInteger full) rem'
                traceWith tr (WeIntentReady wOptsOut)
                let bytes = encodeIntentJSON intent
                case wOptsOut of
                    Nothing -> BSL.putStr bytes
                    Just p -> BSL.writeFile p bytes

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
            case tboOutPath of
                Just p -> BS.writeFile p hexed
                Nothing -> do
                    BS.putStr hexed
                    putStr "\n"
            traceWith tr (TbeWroteCbor tboOutPath)
            if null failures
                then traceWith tr TbeValidationOk
                else do
                    traceWith tr TbeValidationFailed
                    exitFailure

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
                : treasuryUtxos
                ++ [ scopesRef
                   , permissionsRef
                   , treasuryRef
                   , registryRef
                   ]
