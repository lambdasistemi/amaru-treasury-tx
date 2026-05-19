{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
Description : CLI parser and runner for the governance-withdrawal-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
ships the discriminated parser for the two sub-actions
(@proposal@, @materialization@) and the typed @--out@
pre-flight check ('validateOutPath'). The two runner arms
are deliberate stubs that exit non-zero: Slice 2 wires the
@proposal@ live path (registry + stake-reward-accounts
artifact parses + cross-validation + deposit-aware wallet
shortfall + resolver + pure translation to
'SomeTreasuryIntent') and Slice 3 wires @materialization@
on the same resolver shape with a simpler shortfall.

Differences from the stake-reward-init wizard (#159)
parser template:

* Two sub-actions instead of two with different shapes.
* Adds the @--stake-reward-accounts@ shared flag (the
  artifact published by a prior @stake-reward-init-wizard@
  pair of submissions); both subcommands consume it.
* The @proposal@ sub-action adds five operator-typed
  governance flags: two 28-byte key hashes
  (@--funding-stake-key-hash@, @--voter-key-hash@), a
  withdrawal amount, the CIP-1694 anchor URL, and a
  32-byte anchor content hash. Per NFR-008 the wizard
  validates length only; it never reads, hashes, or
  derives key material.
* The @materialization@ sub-action adds one operator-
  observed flag (@--rewards-lovelace@) — the post-
  enactment treasury reward balance the wizard cannot
  query for itself (SC-009 enforces no chain query for
  this value).

Common flags every sub-action shares: @--wallet-addr@,
@--registry@, @--stake-reward-accounts@,
@--funding-seed-txin@, @--out@, @--validity-hours@,
@--log@, @--force@.
-}
module Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
    ( -- * Options
      GovernanceWithdrawalInitWizardOpts (..)
    , ProposalOpts (..)
    , MaterializationOpts (..)

      -- * Parser
    , governanceWithdrawalInitWizardOptsP

      -- * Runner + --out checks
    , runGovernanceWithdrawalInitWizard
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
import System.IO (hPrint, hPutStrLn, stderr)

import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    )
import Amaru.Treasury.LedgerParse
    ( txInFromText
    )
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitError (..)
    )

-- ----------------------------------------------------
-- Option records
-- ----------------------------------------------------

{- | Fields every sub-action shares (wallet, registry-init
artifact path, stake-reward-init accounts artifact path,
funding seed, @--out@, validity-hours, log path,
@--force@).

Slice 1 keeps the per-sub-action option record flat; once
the resolver-driven runner lands (Slices 2-3), the shared
fields may migrate to a common record without breaking
the CLI surface.
-}
data CommonFlags = CommonFlags
    { cfWalletAddr :: !Text
    , cfRegistry :: !FilePath
    , cfStakeRewardAccounts :: !FilePath
    , cfFundingSeedTxIn :: !TxIn
    , cfOut :: !FilePath
    , cfValidityHours :: !(Maybe Word16)
    , cfLog :: !(Maybe FilePath)
    , cfForce :: !Bool
    }
    deriving stock (Eq, Show)

-- | Options for the @proposal@ sub-action.
data ProposalOpts = ProposalOpts
    { poCommon :: !CommonFlags
    , poFundingStakeKeyHash :: !Text
    -- ^ 28-byte (56 hex char), pre-validated by parser
    , poVoterKeyHash :: !Text
    -- ^ 28-byte (56 hex char), pre-validated by parser
    , poWithdrawalAmountLovelace :: !Integer
    -- ^ strictly positive, pre-validated by parser
    , poAnchorUrl :: !Text
    , poAnchorHash :: !Text
    -- ^ 32-byte (64 hex char), pre-validated by parser
    }
    deriving stock (Eq, Show)

-- | Options for the @materialization@ sub-action.
data MaterializationOpts = MaterializationOpts
    { moCommon :: !CommonFlags
    , moRewardsLovelace :: !Integer
    -- ^ strictly positive, pre-validated by parser
    }
    deriving stock (Eq, Show)

-- | Discriminated union dispatched by the runner.
data GovernanceWithdrawalInitWizardOpts
    = GovernanceWithdrawalInitProposalOpts !ProposalOpts
    | GovernanceWithdrawalInitMaterializationOpts !MaterializationOpts
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Parsers
-- ----------------------------------------------------

governanceWithdrawalInitWizardOptsP
    :: Parser GovernanceWithdrawalInitWizardOpts
governanceWithdrawalInitWizardOptsP =
    hsubparser
        ( command
            "proposal"
            ( info
                (GovernanceWithdrawalInitProposalOpts <$> proposalOptsP)
                ( progDesc
                    "Submit the CIP-1694 governance proposal that requests \
                    \a treasury withdrawal and self-vote via a freshly \
                    \registered DRep (devnet only)"
                )
            )
            <> command
                "materialization"
                ( info
                    ( GovernanceWithdrawalInitMaterializationOpts
                        <$> materializationOptsP
                    )
                    ( progDesc
                        "After the proposal enacted, withdraw the observed \
                        \treasury reward balance into the treasury contract \
                        \(devnet only)"
                    )
                )
        )

proposalOptsP :: Parser ProposalOpts
proposalOptsP =
    ProposalOpts
        <$> commonFlagsP
        <*> option
            (hexTextReader 28)
            ( long "funding-stake-key-hash"
                <> metavar "HEX56"
                <> help
                    "28-byte hex key hash of the funding stake key used as \
                    \the proposal's reward-return account"
            )
        <*> option
            (hexTextReader 28)
            ( long "voter-key-hash"
                <> metavar "HEX56"
                <> help
                    "28-byte hex key hash of the voter / DRep key reused as \
                    \voter stake credential, voter payment credential, and \
                    \DRep credential (single-key derivation)"
            )
        <*> option
            positiveIntegerReader
            ( long "withdrawal-amount-lovelace"
                <> metavar "LOVELACE"
                <> help
                    "Strictly positive proposed withdrawal amount in lovelace"
            )
        <*> strOption
            ( long "anchor-url"
                <> metavar "URL"
                <> help "CIP-1694 governance anchor URL"
            )
        <*> option
            (hexTextReader 32)
            ( long "anchor-hash"
                <> metavar "HEX64"
                <> help
                    "32-byte hex blake2b-256 content hash of the anchor \
                    \document at --anchor-url"
            )

materializationOptsP :: Parser MaterializationOpts
materializationOptsP =
    MaterializationOpts
        <$> commonFlagsP
        <*> option
            positiveIntegerReader
            ( long "rewards-lovelace"
                <> metavar "LOVELACE"
                <> help
                    "Strictly positive observed treasury reward balance to \
                    \withdraw (the operator inspects chain state after \
                    \proposal enactment and types the result)"
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
            ( long "registry"
                <> metavar "PATH"
                <> help
                    "Path to the registry-init artifact (devnet JSON \
                    \produced by registry-init-wizard)"
            )
        <*> strOption
            ( long "stake-reward-accounts"
                <> metavar "PATH"
                <> help
                    "Path to the stake-reward-init accounts artifact \
                    \(devnet JSON produced by stake-reward-init-wizard)"
            )
        <*> option
            txInReader
            ( long "funding-seed-txin"
                <> metavar "TXID#IX"
                <> help
                    "Wallet UTxO that pays the proposal deposit (also collateral)"
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

{- | Validate that a string is exactly @expectedBytes@ bytes of
hex (so @2 * expectedBytes@ hex characters) and return the
operator-supplied text verbatim. Reuses
'Amaru.Treasury.IntentJSON.Common.decodeHexBytes' for the
length + hex-character validation; the byte payload is
discarded.

The operator's original casing is preserved unchanged per
NFR-008's verbatim-pass-through contract — the wizard never
normalizes, hashes, or otherwise derives key material. The
validated hex 'Text' is baked verbatim into the resulting
'GovernanceWithdrawalInitProposalAnswers' (and from Slice 2
onward into the per-action intent payload), so that the
operator can audit "what I typed equals what the intent
declared as the required signer key hash".
-}
hexTextReader :: Int -> ReadM Text
hexTextReader expectedBytes =
    eitherReader $ \s ->
        case decodeHexBytes expectedBytes (T.pack s) of
            Left e -> Left e
            Right _ -> Right (T.pack s)

-- | Read a strictly positive 'Integer'.
positiveIntegerReader :: ReadM Integer
positiveIntegerReader =
    eitherReader $ \s -> case reads s of
        [(n :: Integer, "")]
            | n > 0 -> Right n
            | otherwise -> Left ("must be > 0; got " <> s)
        _ -> Left ("not an integer: " <> s)

-- ----------------------------------------------------
-- --out pre-flight checks
-- ----------------------------------------------------

{- | Validate the @--out@ path before any work happens.

The parent directory must exist (otherwise we cannot write
the file), and if the file already exists then @--force@
must have been passed. Both errors surface as typed
'GovernanceWithdrawalInitError' values so the test suite
can pin the behavior without parsing stderr.

The check is split out from
'runGovernanceWithdrawalInitWizard' so the parser tests
can exercise it directly.
-}
validateOutPath
    :: FilePath
    -> Bool
    -> IO (Either GovernanceWithdrawalInitError ())
validateOutPath path force = do
    let parent = takeDirectory path
    parentExists <- doesDirectoryExist parent
    if not parentExists
        then
            pure
                (Left (GovernanceWithdrawalInitOutputParentMissing parent))
        else do
            fileExists <- doesFileExist path
            if fileExists && not force
                then
                    pure
                        ( Left
                            (GovernanceWithdrawalInitOutputExistsNoForce path)
                        )
                else pure (Right ())

-- ----------------------------------------------------
-- Runner
-- ----------------------------------------------------

{- | Top-level dispatcher.

Performs the @--out@ pre-flight check first; on failure
prints the typed 'GovernanceWithdrawalInitError' to stderr
and exits with code 2.

Slice 1 stubs both sub-action runners with non-zero exits:
no chain query, no intent JSON write. Slice 2 wires
@proposal@ and Slice 3 wires @materialization@ on the
resolver-driven shape established by the stake-reward-init
wizard.
-}
runGovernanceWithdrawalInitWizard
    :: GlobalOpts -> GovernanceWithdrawalInitWizardOpts -> IO ()
runGovernanceWithdrawalInitWizard _g cmd = case cmd of
    GovernanceWithdrawalInitProposalOpts (ProposalOpts cf _ _ _ _ _) -> do
        guardOut (cfOut cf) (cfForce cf)
        abortProposalStub
    GovernanceWithdrawalInitMaterializationOpts
        (MaterializationOpts cf _) -> do
            guardOut (cfOut cf) (cfForce cf)
            abortMaterializationStub
  where
    guardOut path force = do
        r <- validateOutPath path force
        case r of
            Right () -> pure ()
            Left e -> do
                hPrint stderr e
                exitWith (ExitFailure 2)

abortProposalStub :: IO a
abortProposalStub = do
    hPutStrLn
        stderr
        "governance-withdrawal-init-wizard proposal: \
        \Slice 1 stub — live path lands in Slice 2 of #160"
    exitWith (ExitFailure 3)

abortMaterializationStub :: IO a
abortMaterializationStub = do
    hPutStrLn
        stderr
        "governance-withdrawal-init-wizard materialization: \
        \Slice 1 stub — live path lands in Slice 3 of #160"
    exitWith (ExitFailure 3)
