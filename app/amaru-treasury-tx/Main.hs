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
* @swap-wizard --network <preprod|mainnet> --wallet-addr ... --registry path\/to\/registry.json --scope ... --ada N.NN --chunks N --min-rate N.NN --validity-hours N --description ... --justification ... --destination-label ... [--signer HEX]... --out path\/intent.json [--yes] [--dry-run] [--verbose] [--force]@
  produces a swap @intent.json@ from a typed questionnaire.
  See [@specs\/002-swap-wizard\/quickstart.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/quickstart.md).
-}
module Main (main) where

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
    , value
    , (<**>)
    )
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes
    ( extractHash
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Aeson (eitherDecodeFileStrict)
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
    , RegistryView (..)
    , ResolverEnv (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , WizardError
    , encodeIntentJSON
    , resolveWizardEnv
    , wizardToIntentJSON
    )

data GlobalOpts = GlobalOpts
    { goSocketPath :: !(Maybe FilePath)
    , goNetworkMagic :: !NetworkMagic
    }

data Cmd
    = CmdSwap SwapOpts
    | CmdSwapWizard WizardOpts

data SwapOpts = SwapOpts
    { soIntentPath :: !FilePath
    , soOutPath :: !(Maybe FilePath)
    }

{- | Flags for the @swap-wizard@ subcommand.
Mirrors @specs/002-swap-wizard/contracts/swap-wizard-cli.md §1@.
-}
data WizardOpts = WizardOpts
    { wOptsNetwork :: !Text
    , wOptsWalletAddr :: !Text
    , wOptsRegistryPath :: !FilePath
    , wOptsOut :: !FilePath
    , wOptsScope :: !ScopeId
    , wOptsAda :: !Double
    -- ^ total ADA to swap (whole ADA, decimals OK)
    , wOptsChunks :: !Int
    -- ^ number of chunks; chunk size is @amount \`div\` chunks@
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
    GlobalOpts
        <$> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> ( NetworkMagic
                <$> option
                    auto
                    ( long "network-magic"
                        <> metavar "WORD32"
                        <> help "Network magic (mainnet=764824073)"
                        <> value 764_824_073
                    )
            )

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

wizardOptsP :: Parser WizardOpts
wizardOptsP =
    WizardOpts
        <$> strOption
            ( long "network"
                <> metavar "NAME"
                <> help "preprod | mainnet"
            )
        <*> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Wallet address (fuel + collateral)"
            )
        <*> strOption
            ( long "registry"
                <> metavar "PATH"
                <> help "Path to RegistryView JSON file"
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
            ( long "ada"
                <> metavar "ADA"
                <> help "Total ADA to swap (decimals OK, e.g. 408163.265306)"
            )
        <*> option
            auto
            ( long "chunks"
                <> metavar "INT"
                <> help "Number of chunks (chunk size = amount / chunks)"
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

{- | Convert decimal ADA to lovelace (1 ADA = 1_000_000 lovelace).
Accepts up to 6 decimal places; anything finer is rounded.
-}
adaToLovelace :: Double -> Integer
adaToLovelace x = round (x * 1_000_000)

{- | Convert decimal USDM-per-ADA rate to (numerator, denominator).
Fixed denominator 1_000_000 matches USDM's 6-decimal precision.
-}
rateToFraction :: Double -> (Integer, Integer)
rateToFraction r = (round (r * 1_000_000), 1_000_000)

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
    -- 1. Load registry view from --registry path.
    rv <- loadRegistry wOptsRegistryPath
    -- 2. Convert human-friendly answers to wire types.
    let amountLov = adaToLovelace wOptsAda
        chunkSize =
            if wOptsChunks <= 0
                then amountLov
                else amountLov `div` toInteger wOptsChunks
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
        ri =
            ResolverInput
                { riNetwork = wOptsNetwork
                , riWalletAddrBech32 = wOptsWalletAddr
                , riScope = wOptsScope
                , riAmountLovelace = amountLov
                , riRegistry = rv
                }
    -- 3. Refuse to overwrite without --force.
    unless wOptsDryRun $
        whenM (doesFileExist wOptsOut) $
            unless wOptsForce $ do
                wizardErr ("output exists: " <> wOptsOut)
                exitWith (ExitFailure 5)
    -- 4. Connect to node, run resolver.
    IO.hPutStrLn stderr $
        "swap-wizard: connecting to " <> socket
    withLocalNodeBackend (goNetworkMagic g) socket $
        \backend -> do
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

loadRegistry :: FilePath -> IO RegistryView
loadRegistry p = do
    r <- eitherDecodeFileStrict p
    case r of
        Right v -> pure v
        Left e -> do
            wizardErr ("registry: " <> e)
            exitWith (ExitFailure 3)

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

txInToText :: TxIn -> Text
txInToText (TxIn (TxId h) ix) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))

nowTip :: Provider IO -> IO Word64
nowTip p = do
    nowSec <- getPOSIXTime
    let nowMs = round (realToFrac nowSec * (1000 :: Double))
    SlotNo s <- posixMsToSlot p nowMs
    pure s

whenM :: (Monad m) => m Bool -> m () -> m ()
whenM cond act = cond >>= \b -> when b act
