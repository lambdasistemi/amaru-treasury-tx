{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ReorganizeWizard
Description : CLI parser and runner for the reorganize-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parser scaffold and live runner for the reorganize wizard.
Exposes the @optparse-applicative@ parser surface for the
@reorganize-wizard@ subcommand, the @--out@ parent-directory
pre-flight ('validateOutPath'), the devnet network guard, and
a runner ('runReorganizeWizard') that resolves live chain state,
builds a reorganize intent, and writes the encoded intent JSON.

The parser reuses 'Amaru.Treasury.LedgerParse.txInFromText'
via 'Options.Applicative.eitherReader' (FR-006). Module
shape mirrors the sibling
'Amaru.Treasury.Cli.RegistryInitWizard' parser scaffold.
-}
module Amaru.Treasury.Cli.ReorganizeWizard
    ( -- * Options
      CommonFlags (..)
    , ReorganizeWizardOpts (..)

      -- * Parser
    , reorganizeWizardOptsP

      -- * Pre-flight + runner shell
    , validateOutPath
    , runReorganizeWizardEither
    , runReorganizeWizardLive
    , exitCodeFor
    , runReorganizeWizard

      -- * Opts → Answers projection
    , optsToAnswers
    ) where

import Control.Exception (IOException, try)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , flag
    , help
    , long
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO (hPrint, stderr)

import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , queryFlatFunds
    , resolveNetworkName
    )
import Amaru.Treasury.IntentJSON
    ( encodeSomeTreasuryIntent
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )
import Amaru.Treasury.Scope (ScopeId, scopeFromText)
import Amaru.Treasury.Tx.ReorganizeWizard
    ( ReorganizeError (..)
    , ReorganizeResolverEnv (..)
    , ReorganizeResolverInput (..)
    , ReorganizeWizardAnswers (..)
    , reorganizeToIntent
    , resolveReorganize
    )

-- ----------------------------------------------------
-- Option records
-- ----------------------------------------------------

{- | Sibling-mirrored shared flag block (verdict B1).

Mirrors 'Amaru.Treasury.Cli.RegistryInitWizard.CommonFlags'
minus the @--bootstrap@ flag (reorganize has no bootstrap
mode — bootstrap-mode is a registry-init concern).
-}
data CommonFlags = CommonFlags
    { cfWalletAddr :: !Text
    , cfMetadataPath :: !FilePath
    , cfOut :: !FilePath
    , cfLog :: !(Maybe FilePath)
    , cfScope :: !ScopeId
    , cfValidityHours :: !(Maybe Word16)
    , cfDescription :: !(Maybe Text)
    , cfJustification :: !(Maybe Text)
    , cfDestinationLabel :: !(Maybe Text)
    , cfEvent :: !(Maybe Text)
    , cfLabel :: !(Maybe Text)
    , cfForce :: !Bool
    }
    deriving stock (Eq, Show)

{- | Parsed reorganize-wizard options.

Flat record — the reorganize wizard has no sub-actions, so
no discriminated union shape (per epic #189's
invariant block).
-}
data ReorganizeWizardOpts = ReorganizeWizardOpts
    { rwoCommon :: !CommonFlags
    , rwoFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Parsers
-- ----------------------------------------------------

{- | @reorganize-wizard@ option parser.

Exposes the sibling-mirrored shared flag block ('CommonFlags')
plus the operator-typed @--funding-seed-txin@ for the
funding seed UTxO. The @--network@ flag is owned by the
global parser
('Amaru.Treasury.Cli.Common.globalOptsP'); it is NOT
redeclared here — the devnet-only invariant is enforced in
the runner pre-flight (see 'runReorganizeWizardEither').
-}
reorganizeWizardOptsP :: Parser ReorganizeWizardOpts
reorganizeWizardOptsP =
    ReorganizeWizardOpts
        <$> commonFlagsP
        <*> option
            txInReader
            ( long "funding-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Funding seed TxIn — fuel + collateral for the reorganize tx"
            )

commonFlagsP :: Parser CommonFlags
commonFlagsP =
    CommonFlags
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
                <> help "Where to write the intent.json"
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
        <*> optional
            ( strOption
                ( long "description"
                    <> metavar "TEXT"
                    <> help "Rationale description override"
                )
            )
        <*> optional
            ( strOption
                ( long "justification"
                    <> metavar "TEXT"
                    <> help "Rationale justification override"
                )
            )
        <*> optional
            ( strOption
                ( long "destination-label"
                    <> metavar "TEXT"
                    <> help "Rationale destination label override"
                )
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
        <*> flag
            False
            True
            ( long "force"
                <> help
                    "Overwrite the file at --out if it already exists"
            )

-- ----------------------------------------------------
-- ReadM helpers
-- ----------------------------------------------------

txInReader :: ReadM TxIn
txInReader = eitherReader (txInFromText . T.pack)

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

-- ----------------------------------------------------
-- --out pre-flight check
-- ----------------------------------------------------

{- | Validate the @--out@ path before any work happens.

The parent directory must exist (otherwise we cannot write
the file), and if the file already exists then @--force@
must have been passed. Both failures surface as typed
'ReorganizeError' values so the test suite can pin the
behavior without parsing stderr.

Mirrors
'Amaru.Treasury.Cli.RegistryInitWizard.validateOutPath' with
the error type swapped to 'ReorganizeError'.
-}
validateOutPath
    :: FilePath -> Bool -> IO (Either ReorganizeError ())
validateOutPath path force = do
    let parent = takeDirectory path
    parentExists <- doesDirectoryExist parent
    if not parentExists
        then pure (Left (ReorganizeOutputParentMissing parent))
        else do
            fileExists <- doesFileExist path
            if fileExists && not force
                then pure (Left (ReorganizeOutputExistsNoForce path))
                else pure (Right ())

-- ----------------------------------------------------
-- Runner shell
-- ----------------------------------------------------

{- | Pre-flight + live runner shell.

Returns the typed 'ReorganizeError' instead of calling
'exitWith' so the test suite can drive the runner without
intercepting 'ExitException'. The 'IO'-exiting
'runReorganizeWizard' is a thin shim over this helper.

The pre-flight ordering is fixed (see
@contracts/exit-code-contract.md@): network guard first
(string compare; cheapest), then @--out@ parent-dir check
(one syscall), then @--node-socket@ presence, then the
live N2C runner body. No chain query, socket open, or file
write happens on any earlier error path.
-}
runReorganizeWizardEither
    :: GlobalOpts
    -> ReorganizeWizardOpts
    -> IO (Either ReorganizeError ())
runReorganizeWizardEither g opts = do
    case resolveNetworkName g of
        Right _ -> stepOut
        Left _ -> pure (Left ReorganizeUnresolvedNetwork)
  where
    cf = rwoCommon opts
    stepOut = do
        r <- validateOutPath (cfOut cf) (cfForce cf)
        case r of
            Left e -> pure (Left e)
            Right () -> case goSocketPath g of
                Nothing -> pure (Left ReorganizeMissingNodeSocket)
                Just socket ->
                    withLocalNodeBackend
                        (goNetworkMagic g)
                        socket
                        $ \backend ->
                            runReorganizeWizardLive
                                g
                                opts
                                (mkLiveEnv backend)

{- | Live reorganize pipeline with injectable resolver
environment.

Builds the resolver input from parsed CLI options, resolves
chain and metadata state, translates the resolved environment
to a reorganize intent, and writes the encoded JSON to
@--out@.
-}
runReorganizeWizardLive
    :: GlobalOpts
    -> ReorganizeWizardOpts
    -> ReorganizeResolverEnv IO
    -> IO (Either ReorganizeError ())
runReorganizeWizardLive g opts renv = do
    let cf = rwoCommon opts
        networkName =
            case resolveNetworkName g of
                Right n -> n
                Left _ -> "<unresolved>"
        input =
            ReorganizeResolverInput
                { rriNetwork = networkName
                , rriWalletAddrBech32 = cfWalletAddr cf
                , rriMetadataPath = cfMetadataPath cf
                , rriScope = cfScope cf
                , rriValidityHours = cfValidityHours cf
                }
    resolved <- resolveReorganize renv input
    case resolved of
        Left e -> pure (Left e)
        Right env -> case reorganizeToIntent env (optsToAnswers opts) of
            Left e -> pure (Left e)
            Right intent -> do
                BSL.writeFile
                    (cfOut cf)
                    (encodeSomeTreasuryIntent intent)
                pure (Right ())

mkLiveEnv :: Backend -> ReorganizeResolverEnv IO
mkLiveEnv backend =
    ReorganizeResolverEnv
        { sreReadMetadata = readMetadataSafely
        , sreQueryWalletUtxos = queryFlat backend
        , sreQueryTreasuryUtxos = queryFlatFunds backend
        , sreComputeUpperBound = \choice -> do
            r <- queryUpperBoundSlot backend choice
            pure (fmap unwrapSlot r)
        }
  where
    unwrapSlot (SlotNo s) = s

{- | Read and decode treasury metadata, surfacing any
'IOException' as resolver data instead of throwing through
the typed runner boundary.
-}
readMetadataSafely
    :: FilePath
    -> IO (Either String TreasuryMetadata)
readMetadataSafely path =
    try (readMetadataFile path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right metadata -> pure (Right metadata)

{- | Map a typed 'ReorganizeError' to the CLI exit code the
runner shim should propagate.

Pre-flight, resolver, configuration, and sparse chain-state
failures surface at exit code 2; malformed ledger-shaped
fields discovered by the runner body surface at exit code 3.
-}
exitCodeFor :: ReorganizeError -> Int
exitCodeFor = \case
    ReorganizeOutputParentMissing{} -> 2
    ReorganizeOutputExistsNoForce{} -> 2
    ReorganizeUnresolvedNetwork -> 2
    ReorganizeMissingNodeSocket -> 2
    ReorganizeMetadataReadError{} -> 2
    ReorganizeScopeNotInMetadata{} -> 2
    ReorganizeScopeOwnerMissing{} -> 2
    ReorganizeInsufficientTreasuryUtxos{} -> 2
    ReorganizeWalletShortfall -> 2
    ReorganizeValidityHoursZero -> 2
    ReorganizeValidityOvershoot{} -> 2
    ReorganizeLedgerFieldParseError{} -> 3

{- | Top-level reorganize-wizard runner.

Thin shim over 'runReorganizeWizardEither' that maps the
typed error to a stderr trace + 'exitWith' so the binary
exits non-zero on the error path.
-}
runReorganizeWizard
    :: GlobalOpts -> ReorganizeWizardOpts -> IO ()
runReorganizeWizard g opts = do
    r <- runReorganizeWizardEither g opts
    case r of
        Right () -> pure ()
        Left e -> do
            hPrint stderr e
            exitWith (ExitFailure (exitCodeFor e))

-- ----------------------------------------------------
-- Opts → Answers projection
-- ----------------------------------------------------

{- | Project a parsed 'ReorganizeWizardOpts' to the typed
'ReorganizeWizardAnswers' record the runner body consumes.

Shipped on the Cli side (rather than in the @Tx@ module
where 'ReorganizeWizardAnswers' lives) because the source
record 'ReorganizeWizardOpts' is itself a Cli concern;
putting the projection in @Tx@ would force a circular
import.
-}
optsToAnswers :: ReorganizeWizardOpts -> ReorganizeWizardAnswers
optsToAnswers ReorganizeWizardOpts{rwoCommon = cf, rwoFundingSeedTxIn = txin} =
    ReorganizeWizardAnswers
        { rwaWalletAddr = cfWalletAddr cf
        , rwaMetadataPath = cfMetadataPath cf
        , rwaScope = cfScope cf
        , rwaValidityHours = cfValidityHours cf
        , rwaDescription = cfDescription cf
        , rwaJustification = cfJustification cf
        , rwaDestinationLabel = cfDestinationLabel cf
        , rwaEvent = cfEvent cf
        , rwaLabel = cfLabel cf
        , rwaFundingSeedTxIn = txin
        }
