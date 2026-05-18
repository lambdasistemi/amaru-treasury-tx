{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.StakeRewardInitWizard
Description : CLI parser and runner for the stake-reward-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
ships the discriminated parser for the two sub-actions
(@script-account@, @plain-account@) and the typed @--out@
pre-flight check ('validateOutPath'). The two runner arms
are deliberate stubs that error out: Slice 2 wires the
@script-account@ live path (registry-file parse + resolver
+ pure translation to 'SomeTreasuryIntent') and Slice 3
wires @plain-account@ on the same shape.

Differences from the registry-init wizard (#158) parser
template:

* Two sub-actions instead of three.
* No rationale flag set (@--description@, @--justification@,
  @--destination-label@, @--event@, @--label@).
* No @--scope@ / @--metadata@ / @--owner-key-hash@ /
  @--scopes-seed-txin@ / @--registry-seed-txin@.
* @--registry@ is a plain file path ('strOption'); the
  registry-init artifact is parsed at the resolver layer in
  Slice 2 via 'readDevnetStakeRewardRegistry'.
* @--funding-seed-txin@ is the only operator-typed TxIn; it
  reuses 'Amaru.Treasury.LedgerParse.txInFromText' via
  'eitherReader'.

Common flags every sub-action shares: @--wallet-addr@,
@--registry@, @--funding-seed-txin@, @--out@,
@--validity-hours@, @--log@, @--force@.
-}
module Amaru.Treasury.Cli.StakeRewardInitWizard
    ( -- * Options
      StakeRewardInitWizardOpts (..)
    , ScriptAccountOpts (..)
    , PlainAccountOpts (..)

      -- * Parser
    , stakeRewardInitWizardOptsP

      -- * Runner + --out checks
    , runStakeRewardInitWizard
    , validateOutPath
    ) where

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
import System.IO (hPrint, stderr)

import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    )
import Amaru.Treasury.LedgerParse
    ( txInFromText
    )
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitError (..)
    )

-- ----------------------------------------------------
-- Option records
-- ----------------------------------------------------

{- | Fields every sub-action shares (wallet, registry-init
artifact path, funding seed, @--out@, validity-hours, log
path, @--force@).

Slice 1 keeps the per-sub-action option record flat — once
the resolver-driven runner lands (Slices 2-3), the shared
fields may migrate to a common record without breaking the
CLI surface.
-}
data CommonFlags = CommonFlags
    { cfWalletAddr :: !Text
    , cfRegistry :: !FilePath
    , cfFundingSeedTxIn :: !TxIn
    , cfOut :: !FilePath
    , cfValidityHours :: !(Maybe Word16)
    , cfLog :: !(Maybe FilePath)
    , cfForce :: !Bool
    }
    deriving stock (Eq, Show)

-- | Options for the @script-account@ sub-action.
newtype ScriptAccountOpts = ScriptAccountOpts
    { saCommon :: CommonFlags
    }
    deriving stock (Eq, Show)

-- | Options for the @plain-account@ sub-action.
newtype PlainAccountOpts = PlainAccountOpts
    { paCommon :: CommonFlags
    }
    deriving stock (Eq, Show)

-- | Discriminated union dispatched by the runner.
data StakeRewardInitWizardOpts
    = StakeRewardInitScriptAccountOpts !ScriptAccountOpts
    | StakeRewardInitPlainAccountOpts !PlainAccountOpts
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Parsers
-- ----------------------------------------------------

stakeRewardInitWizardOptsP :: Parser StakeRewardInitWizardOpts
stakeRewardInitWizardOptsP =
    hsubparser
        ( command
            "script-account"
            ( info
                (StakeRewardInitScriptAccountOpts <$> scriptAccountOptsP)
                ( progDesc
                    "Register a script-based stake-reward account using the funding seed"
                )
            )
            <> command
                "plain-account"
                ( info
                    (StakeRewardInitPlainAccountOpts <$> plainAccountOptsP)
                    ( progDesc
                        "Register a plain (vkey) stake-reward account using the funding seed"
                    )
                )
        )

scriptAccountOptsP :: Parser ScriptAccountOpts
scriptAccountOptsP = ScriptAccountOpts <$> commonFlagsP

plainAccountOptsP :: Parser PlainAccountOpts
plainAccountOptsP = PlainAccountOpts <$> commonFlagsP

commonFlagsP :: Parser CommonFlags
commonFlagsP =
    CommonFlags
        <$> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Wallet address (fuel + collateral)"
            )
        <*> strOption
            ( long "registry"
                <> metavar "PATH"
                <> help
                    "Path to the registry-init artifact (devnet JSON \
                    \produced by registry-init-wizard)"
            )
        <*> option
            txInReader
            ( long "funding-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Wallet UTxO that pays the registration deposit"
            )
        <*> strOption
            ( long "out"
                <> short 'o'
                <> metavar "PATH"
                <> help "Where to write the intent.json"
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
                ( long "log"
                    <> metavar "PATH"
                    <> help
                        "Where to write step-by-step trace lines (defaults to stderr)"
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
txInReader =
    eitherReader (txInFromText . T.pack)

-- ----------------------------------------------------
-- --out pre-flight checks
-- ----------------------------------------------------

{- | Validate the @--out@ path before any work happens.

The parent directory must exist (otherwise we cannot write
the file), and if the file already exists then @--force@
must have been passed. Both errors surface as typed
'StakeRewardInitError' values so the test suite can pin the
behavior without parsing stderr.

The check is split out from 'runStakeRewardInitWizard' so
the parser tests can exercise it directly.
-}
validateOutPath
    :: FilePath -> Bool -> IO (Either StakeRewardInitError ())
validateOutPath path force = do
    let parent = takeDirectory path
    parentExists <- doesDirectoryExist parent
    if not parentExists
        then pure (Left (StakeRewardInitOutputParentMissing parent))
        else do
            fileExists <- doesFileExist path
            if fileExists && not force
                then pure (Left (StakeRewardInitOutputExistsNoForce path))
                else pure (Right ())

-- ----------------------------------------------------
-- Runner
-- ----------------------------------------------------

{- | Top-level dispatcher.

Performs the @--out@ pre-flight check first; on failure
prints the typed 'StakeRewardInitError' to stderr and exits
with code 2.

Slice 1 stubs both sub-action runners with 'error' calls
that produce non-zero exits; Slice 2 wires
@script-account@ and Slice 3 wires @plain-account@ on the
same resolver-driven shape used by the registry-init
wizard.
-}
runStakeRewardInitWizard
    :: GlobalOpts -> StakeRewardInitWizardOpts -> IO ()
runStakeRewardInitWizard _g cmd = case cmd of
    StakeRewardInitScriptAccountOpts (ScriptAccountOpts cf) -> do
        guardOut (cfOut cf) (cfForce cf)
        error "TODO Slice 2: stake-reward-init-wizard script-account"
    StakeRewardInitPlainAccountOpts (PlainAccountOpts cf) -> do
        guardOut (cfOut cf) (cfForce cf)
        error "TODO Slice 3: stake-reward-init-wizard plain-account"
  where
    guardOut path force = do
        r <- validateOutPath path force
        case r of
            Right () -> pure ()
            Left e -> do
                hPrint stderr e
                exitWith (ExitFailure 2)
