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

* @swap --intent path\/to\/intent.json [--out path\/swap.cbor]@ —
  builds the SundaeSwap order tx for a treasury scope.
  See [@docs\/swap.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/docs/swap.md).
* @swap-wizard --network <preprod|mainnet> --wallet-addr ... --metadata path\/to\/metadata.json --scope ... --usdm N.NN --split N --min-rate N.NN --validity-hours N --description ... --justification ... --destination-label ... [--signer HEX]... --out path\/intent.json [--yes] [--dry-run] [--verbose] [--force]@
  produces a swap @intent.json@ from a typed questionnaire.
  See [@specs\/002-swap-wizard\/quickstart.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/quickstart.md).
-}
module Main (main) where

import Control.Applicative ((<|>))
import Control.Exception (throwIO)
import Control.Monad (unless, when)
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
    , switch
    , (<**>)
    )
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
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
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.Swap (SwapIntent (..))
import Amaru.Treasury.Tx.SwapBuild
    ( ScriptResult (..)
    , SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )
import Amaru.Treasury.Tx.SwapIntentJSON
    ( TranslatedIntent (..)
    , decodeSwapIntentFile
    , parseAddr
    , translateIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RationaleAnswers (..)
    , ResolverEnv (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , WizardError
    , encodeIntentJSON
    , registryViewFromVerified
    , resolveWizardEnv
    , txInToText
    , wizardToIntentJSON
    )

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

data SwapOpts = SwapOpts
    { soIntentPath :: !FilePath
    , soOutPath :: !(Maybe FilePath)
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
    , wOptsOut :: !FilePath
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
    -- ^ accumulated @--signer@ flags; empty = use scope default
    , wOptsYes :: !Bool
    , wOptsDryRun :: !Bool
    , wOptsVerbose :: !Bool
    , wOptsForce :: !Bool
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
        <$> strOption
            ( long "intent"
                <> short 'i'
                <> metavar "PATH"
                <> help "Path to the swap-intent JSON"
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
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
                    "Build a SundaeSwap treasury swap (ADA→USDM)"
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
        <*> strOption
            ( long "out"
                <> short 'o'
                <> metavar "PATH"
                <> help "Where to write intent.json"
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
                ( long "signer"
                    <> metavar "HEX"
                    <> help "Repeat for each override signer (28-byte hex)"
                )
            )
        <*> switch
            ( long "yes"
                <> help "Skip confirmation"
            )
        <*> switch
            ( long "dry-run"
                <> help "Print JSON to stdout, skip file write"
            )
        <*> switch
            ( long "verbose"
                <> help "Print resolved env summary on stderr"
            )
        <*> switch
            ( long "force"
                <> help "Overwrite --out if it exists"
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
    IO.hPutStrLn stderr $
        "amaru-treasury-tx swap: reading "
            <> soIntentPath
    parsed <- decodeSwapIntentFile soIntentPath
    case parsed of
        Left e ->
            throwIO . userError $
                "intent JSON: " <> e
        Right sij -> case translateIntent sij of
            Left e ->
                throwIO . userError $
                    "intent translation: " <> e
            Right TranslatedIntent{..} -> do
                IO.hPutStrLn stderr $
                    "amaru-treasury-tx swap: connecting to "
                        <> socket
                withLocalNodeBackend
                    (goNetworkMagic g)
                    socket
                    $ \backend -> do
                        let intent = tiSwapIntent
                            allRequired =
                                Set.fromList $
                                    tiWalletTxIn
                                        : siTreasuryUtxos intent
                                        ++ [ siScopesDeployedAt
                                                intent
                                           , siPermissionsDeployedAt
                                                intent
                                           , siTreasuryDeployedAt
                                                intent
                                           , siRegistryDeployedAt
                                                intent
                                           ]
                        ctx <- liveContext backend allRequired
                        let inputs =
                                SwapBuildInputs
                                    { sbiIntent = intent
                                    , sbiRationale =
                                        tiRationale
                                    , sbiWalletTxIn =
                                        tiWalletTxIn
                                    , sbiWalletAddr =
                                        tiWalletAddr
                                    }
                        SwapBuildResult{..} <-
                            runSwapBuild ctx inputs
                        let cborStrict =
                                BSL.toStrict sbrCborBytes
                            hexed = B16.encode cborStrict
                            Coin feeLov = sbrFeeLovelace
                            Coin tcLov =
                                sbrTotalCollateralLovelace
                            failures =
                                [ (purpose, e)
                                | ScriptResult
                                    purpose
                                    (Left e) <-
                                    sbrScriptResults
                                ]
                        IO.hPutStrLn stderr $
                            "amaru-treasury-tx swap: "
                                <> show
                                    (BS.length cborStrict)
                                <> " bytes  fee="
                                <> show feeLov
                                <> "  total_collateral="
                                <> show tcLov
                        IO.hPutStrLn stderr $
                            "amaru-treasury-tx swap: "
                                <> "re-evaluated "
                                <> show
                                    (length sbrScriptResults)
                                <> " redeemers, "
                                <> show (length failures)
                                <> " failed"
                        mapM_
                            ( \(p, e) ->
                                IO.hPutStrLn stderr $
                                    "  FAIL: "
                                        <> show p
                                        <> " — "
                                        <> e
                            )
                            failures
                        case soOutPath of
                            Just p -> BS.writeFile p hexed
                            Nothing -> do
                                BS.putStr hexed
                                putStr "\n"
                        if null failures
                            then
                                IO.hPutStrLn
                                    stderr
                                    "amaru-treasury-tx swap: VALIDATION OK"
                            else do
                                IO.hPutStrLn
                                    stderr
                                    "amaru-treasury-tx swap: VALIDATION FAILED"
                                exitFailure

-- ----------------------------------------------------
-- swap-wizard subcommand
-- ----------------------------------------------------

runWizard :: GlobalOpts -> WizardOpts -> IO ()
runWizard g wo@WizardOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    network <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> do
            wizardErr e
            exitWith (ExitFailure 3)
    -- 1. Convert human-friendly answers to wire types.
    --    The user buys USDM at rate 'min-rate' (USDM/ADA);
    --    ADA spend = usdm / rate.
    let amountLov = usdmToLovelace wOptsUsdm wOptsMinRate
        chunkSize = case wOptsChunkSpec of
            -- 'positiveSplit' rejects N < 1 at parse time.
            SplitCount n -> amountLov `div` toInteger n
            ChunkUsdm x -> usdmToLovelace x wOptsMinRate
        (rateNum, rateDen) = rateToFraction wOptsMinRate
        signersOverride =
            if null wOptsSigners
                then Nothing
                else Just wOptsSigners
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
                , wqSignersOverride = signersOverride
                }
    -- 2. Refuse to overwrite without --force.
    unless wOptsDryRun $
        whenM (doesFileExist wOptsOut) $
            unless wOptsForce $ do
                wizardErr ("output exists: " <> wOptsOut)
                exitWith (ExitFailure 5)
    -- 3. Connect to node, verify the local metadata, run resolver.
    IO.hPutStrLn stderr $
        "swap-wizard: connecting to " <> socket
    withLocalNodeBackend (goNetworkMagic g) socket $
        \backend -> do
            verified <-
                verifyRegistry
                    backend
                    wOptsMetadataPath
                    (Set.singleton wOptsScope)
            rv <- case verified of
                Left e -> do
                    wizardErr ("metadata: " <> show e)
                    exitWith (ExitFailure 3)
                Right registry ->
                    case registryViewFromVerified wOptsScope registry of
                        Left e -> do
                            wizardErr ("metadata: " <> show e)
                            exitWith (ExitFailure 3)
                        Right view -> pure view
            let ri =
                    ResolverInput
                        { riNetwork = network
                        , riWalletAddrBech32 = wOptsWalletAddr
                        , riScope = wOptsScope
                        , riAmountLovelace = amountLov
                        , riRegistry = rv
                        }
            let renv = providerToResolverEnv backend
            er <- resolveWizardEnv renv ri
            case er of
                Left e -> do
                    wizardErr (show e)
                    exitWith (ExitFailure 3)
                Right env -> do
                    when wOptsVerbose (printEnvSummary env)
                    case wizardToIntentJSON env answers of
                        Left we -> do
                            wizardErr (show (we :: WizardError))
                            exitWith (ExitFailure 4)
                        Right intent -> do
                            confirmed <- askConfirm wo
                            unless confirmed $
                                exitWith (ExitFailure 1)
                            let bytes = encodeIntentJSON intent
                            if wOptsDryRun
                                then BSL.putStr bytes
                                else do
                                    BSL.writeFile wOptsOut bytes
                                    putStrLn $
                                        "wrote intent.json to "
                                            <> wOptsOut

wizardErr :: String -> IO ()
wizardErr s = IO.hPutStrLn stderr ("swap-wizard: " <> s)

printEnvSummary :: WizardEnv -> IO ()
printEnvSummary e = do
    let l = T.unpack
    IO.hPutStrLn stderr "swap-wizard: resolved environment"
    IO.hPutStrLn stderr $
        "  network        = " <> l (weNetwork e)
    IO.hPutStrLn stderr $
        "  currentTip     = " <> show (weCurrentTip e)
    IO.hPutStrLn stderr $
        "  walletTxIn     = "
            <> l (wsTxIn (weWalletSelection e))
    IO.hPutStrLn stderr $
        "  walletAddr     = "
            <> l (wsAddress (weWalletSelection e))

askConfirm :: WizardOpts -> IO Bool
askConfirm WizardOpts{..}
    | wOptsYes = pure True
    | otherwise = do
        IO.hPutStr
            stderr
            "Confirm and write intent.json? [y/N] "
        IO.hFlush stderr
        ln <- TIO.hGetLine IO.stdin
        pure $ T.toLower (T.strip ln) == "y"

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

whenM :: (Monad m) => m Bool -> m () -> m ()
whenM cond act = cond >>= \b -> when b act
