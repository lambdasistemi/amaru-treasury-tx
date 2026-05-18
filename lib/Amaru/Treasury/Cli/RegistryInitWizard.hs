{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.RegistryInitWizard
Description : CLI parser and runner stub for registry-init-wizard (Slice 1 of #158)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 ships:

* 'RegistryInitWizardOpts' — the discriminated union of
  per-sub-action option records ('SeedSplitOpts', 'MintOpts',
  'ReferenceScriptsOpts').
* 'registryInitWizardOptsP' — three optparse-applicative
  subcommands wrapped under @registry-init-wizard@.
* 'validateOutPath' — pure-ish @--out@ pre-flight: parent
  directory must exist; existing file requires @--force@.
* 'runRegistryInitWizard' — runs 'validateOutPath' then prints
  a typed TODO and exits non-zero. Slices 2-4 replace each
  TODO with the live resolve → translate → encode → write path.

The parser reuses 'Amaru.Treasury.LedgerParse.txInFromText'
and 'Amaru.Treasury.LedgerParse.keyHashFromHex' via
'Options.Applicative.eitherReader'; there is no local hex-28
or @txid#ix@ parser.
-}
module Amaru.Treasury.Cli.RegistryInitWizard
    ( -- * Options
      RegistryInitWizardOpts (..)
    , SeedSplitOpts (..)
    , MintOpts (..)
    , ReferenceScriptsOpts (..)

      -- * Parser
    , registryInitWizardOptsP

      -- * Runner + --out checks
    , runRegistryInitWizard
    , validateOutPath
    ) where

import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , command
    , eitherReader
    , flag
    , help
    , hsubparser
    , info
    , long
    , metavar
    , option
    , optional
    , progDesc
    , short
    , strOption
    )
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO (hPrint, hPutStrLn, stderr)

import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.LedgerParse
    ( keyHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitError (..)
    )

-- ----------------------------------------------------
-- Option records
-- ----------------------------------------------------

{- | Fields every sub-action shares (wallet, metadata,
@--out@, scope, validity, rationale overrides, log path,
collision force flag).

Slice 1 keeps the per-sub-action option record flat — once
Slice 2 introduces the resolver-driven runner, common fields
may migrate to a shared record without breaking the CLI
surface.
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

-- | Options for the @seed-split@ sub-action.
newtype SeedSplitOpts = SeedSplitOpts
    { ssCommon :: CommonFlags
    }
    deriving stock (Eq, Show)

-- | Options for the @mint@ sub-action.
data MintOpts = MintOpts
    { mCommon :: !CommonFlags
    , mScopesSeedTxIn :: !TxIn
    , mRegistrySeedTxIn :: !TxIn
    , mOwnerKeyHash :: !(KeyHash Witness)
    }
    deriving stock (Eq, Show)

-- | Options for the @reference-scripts@ sub-action.
data ReferenceScriptsOpts = ReferenceScriptsOpts
    { rsCommon :: !CommonFlags
    , rsScopesSeedTxIn :: !TxIn
    , rsRegistrySeedTxIn :: !TxIn
    , rsFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

-- | Discriminated union dispatched by the runner.
data RegistryInitWizardOpts
    = RegistryInitSeedSplitOpts !SeedSplitOpts
    | RegistryInitMintOpts !MintOpts
    | RegistryInitReferenceScriptsOpts !ReferenceScriptsOpts
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Parsers
-- ----------------------------------------------------

registryInitWizardOptsP :: Parser RegistryInitWizardOpts
registryInitWizardOptsP =
    hsubparser
        ( command
            "seed-split"
            ( info
                (RegistryInitSeedSplitOpts <$> seedSplitOptsP)
                ( progDesc
                    "Split the funding seed UTxO into the three seed UTxOs (scopes, registry, funding)"
                )
            )
            <> command
                "mint"
                ( info
                    (RegistryInitMintOpts <$> mintOptsP)
                    ( progDesc
                        "Mint the scopes and registry NFTs using the seeds from seed-split"
                    )
                )
            <> command
                "reference-scripts"
                ( info
                    (RegistryInitReferenceScriptsOpts <$> referenceScriptsOptsP)
                    ( progDesc
                        "Publish the reference scripts using the funding seed from seed-split"
                    )
                )
        )

seedSplitOptsP :: Parser SeedSplitOpts
seedSplitOptsP = SeedSplitOpts <$> commonFlagsP

mintOptsP :: Parser MintOpts
mintOptsP =
    MintOpts
        <$> commonFlagsP
        <*> option
            txInReader
            ( long "scopes-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Scopes seed TxIn — first output of the seed-split sub-tx"
            )
        <*> option
            txInReader
            ( long "registry-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Registry seed TxIn — second output of the seed-split sub-tx"
            )
        <*> option
            keyHashReader
            ( long "owner-key-hash"
                <> metavar "HEX28"
                <> help
                    "28-byte hex; scope owner key hash baked into the scopes NFT datum"
            )

referenceScriptsOptsP :: Parser ReferenceScriptsOpts
referenceScriptsOptsP =
    ReferenceScriptsOpts
        <$> commonFlagsP
        <*> option
            txInReader
            ( long "scopes-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Scopes seed TxIn used for script derivation"
            )
        <*> option
            txInReader
            ( long "registry-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Registry seed TxIn used for script derivation"
            )
        <*> option
            txInReader
            ( long "funding-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Funding seed TxIn — third output of the seed-split sub-tx; pays reference-scripts deposits"
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

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

txInReader :: ReadM TxIn
txInReader =
    eitherReader (txInFromText . T.pack)

keyHashReader :: ReadM (KeyHash Witness)
keyHashReader =
    eitherReader (keyHashFromHex . T.pack)

-- ----------------------------------------------------
-- --out pre-flight checks
-- ----------------------------------------------------

{- | Validate the @--out@ path before any work happens.

The parent directory must exist (otherwise we cannot write
the file), and if the file already exists then @--force@
must have been passed. Both errors surface as typed
'RegistryInitError' values so the test suite can pin the
behavior without parsing stderr.

The check is split out from 'runRegistryInitWizard' so the
parser tests can exercise it directly.
-}
validateOutPath
    :: FilePath -> Bool -> IO (Either RegistryInitError ())
validateOutPath path force = do
    let parent = takeDirectory path
    parentExists <- doesDirectoryExist parent
    if not parentExists
        then pure (Left (RegistryInitOutputParentMissing parent))
        else do
            fileExists <- doesFileExist path
            if fileExists && not force
                then pure (Left (RegistryInitOutputExistsNoForce path))
                else pure (Right ())

-- ----------------------------------------------------
-- Runner (Slice 1: TODO stub after --out checks)
-- ----------------------------------------------------

{- | Slice 1 runner.

Performs the @--out@ pre-flight check then exits with a
typed TODO for the matching sub-action. Slices 2-4 replace
each arm with the live resolve → translate → encode → write
path.

The exit codes distinguish two non-zero outcomes:

* @2@ — @--out@ pre-flight failed (typed
  'RegistryInitError' printed to stderr).
* @3@ — pre-flight passed but the live path is not yet
  wired (TODO).
-}
runRegistryInitWizard
    :: GlobalOpts -> RegistryInitWizardOpts -> IO ()
runRegistryInitWizard _g cmd = case cmd of
    RegistryInitSeedSplitOpts SeedSplitOpts{..} -> do
        guardOut (cfOut ssCommon) (cfForce ssCommon)
        todoExit "seed-split" 2
    RegistryInitMintOpts MintOpts{..} -> do
        guardOut (cfOut mCommon) (cfForce mCommon)
        todoExit "mint" 3
    RegistryInitReferenceScriptsOpts ReferenceScriptsOpts{..} -> do
        guardOut (cfOut rsCommon) (cfForce rsCommon)
        todoExit "reference-scripts" 4
  where
    guardOut path force = do
        r <- validateOutPath path force
        case r of
            Right () -> pure ()
            Left e -> do
                hPrint stderr e
                exitWith (ExitFailure 2)
    todoExit name sliceN = do
        hPutStrLn
            stderr
            ( "TODO: Slice "
                <> show (sliceN :: Int)
                <> " wires the live path for "
                <> name
            )
        exitWith (ExitFailure 3)
