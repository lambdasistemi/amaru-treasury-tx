{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ReorganizeWizard
Description : CLI parser and stub runner for the reorganize-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of #186 — parser scaffold + TODO-stub runner.
Exposes the @optparse-applicative@ parser surface for the
@reorganize-wizard@ subcommand, the @--out@ parent-directory
pre-flight ('validateOutPath'), the devnet network guard, and
a stub runner ('runReorganizeWizard') that surfaces a typed
'ReorganizeTodoSliceC' error from the runner shell. The
runner body — chain query, treasury UTxO selection,
validity-bound sampling, intent encode — lands in #187 and is
out of scope for this slice.

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
    , exitCodeFor
    , runReorganizeWizard

      -- * Opts → Answers projection
    , optsToAnswers
    ) where

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

import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Amaru.Treasury.Scope (ScopeId, scopeFromText)
import Amaru.Treasury.Tx.ReorganizeWizard
    ( ReorganizeError (..)
    , ReorganizeWizardAnswers (..)
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

{- | Pre-flight + stub runner shell.

Returns the typed 'ReorganizeError' instead of calling
'exitWith' so the test suite can drive the runner without
intercepting 'ExitException'. The 'IO'-exiting
'runReorganizeWizard' is a thin shim over this helper.

The pre-flight ordering is fixed (see
@contracts/exit-code-contract.md@): network guard first
(string compare; cheapest), then @--out@ parent-dir check
(one syscall), then the stub runner body. No chain query,
no socket open, no file write happens on any error path.
-}
runReorganizeWizardEither
    :: GlobalOpts
    -> ReorganizeWizardOpts
    -> IO (Either ReorganizeError ())
runReorganizeWizardEither g opts = do
    case resolveNetworkName g of
        Right "devnet" -> stepOut
        Right other ->
            pure (Left (ReorganizeNonDevnetNetwork other))
        Left _ ->
            pure (Left (ReorganizeNonDevnetNetwork "<unresolved>"))
  where
    cf = rwoCommon opts
    stepOut = do
        r <- validateOutPath (cfOut cf) (cfForce cf)
        case r of
            Left e -> pure (Left e)
            Right () -> pure (Left ReorganizeTodoSliceC)

{- | Map a typed 'ReorganizeError' to the CLI exit code the
runner shim should propagate.

Pre-flight failures surface at exit code 2; the
runner-stub marker surfaces at exit code 3. #187 may grow
the runner-body variants — those will also exit 3 (typed
runner failures) per the sibling convention.
-}
exitCodeFor :: ReorganizeError -> Int
exitCodeFor = \case
    ReorganizeOutputParentMissing{} -> 2
    ReorganizeOutputExistsNoForce{} -> 2
    ReorganizeNonDevnetNetwork{} -> 2
    ReorganizeTodoSliceC -> 3

{- | Top-level reorganize-wizard runner.

Thin shim over 'runReorganizeWizardEither' that maps the
typed error to a stderr trace + 'exitWith' so the binary
exits non-zero on the error path. #187's runner body
extends 'runReorganizeWizardEither' (the typed Either
boundary) rather than this shim.
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
'ReorganizeWizardAnswers' record the #187 runner body will
consume.

Shipped on the Cli side (rather than in the @Tx@ module
where 'ReorganizeWizardAnswers' lives) because the source
record 'ReorganizeWizardOpts' is itself a Cli concern;
putting the projection in @Tx@ would force a circular
import. The Slice-1 stub runner does not yet call this —
it short-circuits at 'ReorganizeTodoSliceC' — but #187
will.
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
