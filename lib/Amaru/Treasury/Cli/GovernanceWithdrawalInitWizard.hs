{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
Description : CLI parser and runner for the governance-withdrawal-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
shipped the discriminated parser for the two sub-actions
(@proposal@, @materialization@) and the typed @--out@
pre-flight check ('validateOutPath'). Slice 2 (this slice)
wires the @proposal@ live path:

* artifact-file parses via the existing
  'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceWithdrawalRegistry'
  and
  'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceStakeRewardAccounts';
* cross-validation via
  'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.validateGovernanceWithdrawalPrerequisites';
* devnet-only network guard fires BEFORE any chain query
  or artifact parse;
* deposit-aware wallet-shortfall check (FR-008) using the
  three deposit fields read from chain pparams plus the
  two locally-named constants for @voteOutputCoin@ and
  @estimatedFee@;
* pure translation via
  'Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard.governanceWithdrawalInitProposalToIntent'
  → 'Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent' →
  atomic @--out@ write honoring @--force@.

Slice 3 will wire @materialization@ on the same shape with
a simpler shortfall (no governance deposits).

Differences from the stake-reward-init wizard (#159)
parser template are listed in
'Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard'; the
parser surface is unchanged from Slice 1.
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

import Control.Exception (IOException, catch, onException, try)
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
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
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , removeFile
    , renameFile
    )
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO
    ( hClose
    , hPrint
    , hPutStrLn
    , openTempFile
    , stderr
    )

import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.ChainContext
    ( ChainContext (..)
    , networkFromMagic
    , withLiveContext
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , resolveNetworkName
    )
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccounts
    , DevnetGovernanceWithdrawalRegistry
    , readDevnetGovernanceStakeRewardAccounts
    , readDevnetGovernanceWithdrawalRegistry
    )
import Amaru.Treasury.IntentJSON
    ( encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    )
import Amaru.Treasury.LedgerParse
    ( txInFromText
    )
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitError (..)
    , GovernanceWithdrawalInitMaterializationAnswers (..)
    , GovernanceWithdrawalInitMaterializationResolverEnv (..)
    , GovernanceWithdrawalInitProposalAnswers (..)
    , GovernanceWithdrawalInitResolverEnv (..)
    , GovernanceWithdrawalInitResolverInput (..)
    , defaultMaterializationFloorComponents
    , extractDepositComponents
    , governanceWithdrawalInitMaterializationToIntent
    , governanceWithdrawalInitProposalToIntent
    , resolveGovernanceWithdrawalInitMaterialization
    , resolveGovernanceWithdrawalInitProposal
    )

-- ----------------------------------------------------
-- Option records
-- ----------------------------------------------------

{- | Fields every sub-action shares (wallet, registry-init
artifact path, stake-reward-init accounts artifact path,
funding seed, @--out@, validity-hours, log path,
@--force@).

Slice 1 kept the per-sub-action option record flat; once
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

Slice 2 wires the @proposal@ live path; @materialization@
remains a stub that exits non-zero and writes nothing
(Slice 3).
-}
runGovernanceWithdrawalInitWizard
    :: GlobalOpts -> GovernanceWithdrawalInitWizardOpts -> IO ()
runGovernanceWithdrawalInitWizard g cmd = case cmd of
    GovernanceWithdrawalInitProposalOpts po -> do
        let cf = poCommon po
        guardOut (cfOut cf) (cfForce cf)
        runProposal g po
    GovernanceWithdrawalInitMaterializationOpts mo -> do
        let cf = moCommon mo
        guardOut (cfOut cf) (cfForce cf)
        runMaterialization g mo
  where
    guardOut path force = do
        r <- validateOutPath path force
        case r of
            Right () -> pure ()
            Left e -> do
                hPrint stderr e
                exitWith (ExitFailure 2)

-- ----------------------------------------------------
-- Live proposal runner
-- ----------------------------------------------------

{- | Live @proposal@ path. The order matters and is enforced
by the structure of this function:

1. Resolve CLI inputs (network name + socket) — pure
   text/file checks, no chain query.
2. Open the node connection via 'withLocalNodeBackend'.
   This is a socket dial, not a query.
3. Build the resolver input + 'GovernanceWithdrawalInitResolverEnv'.
   The 'gwireDepositComponents' field is a LAZY @IO@
   action that, when forced, runs 'withLiveContext' to
   acquire pparams and projects them through
   'extractDepositComponents'. Crucially, the
   @withLiveContext@ call is INSIDE this lazy action —
   it does not fire if the resolver short-circuits before
   reaching the deposit-aware shortfall check.
4. Invoke 'resolveGovernanceWithdrawalInitProposal'. The
   resolver fires its devnet network guard as the FIRST
   check; on any non-@"devnet"@ network it returns
   'GovernanceWithdrawalInitNonDevnetNetwork' BEFORE
   touching any artifact, any wallet query, AND BEFORE
   forcing 'gwireDepositComponents' (so no pparams query
   either). The same short-circuit applies to subsequent
   failures: registry parse, accounts parse, cross-
   validation.
5. Translate via 'governanceWithdrawalInitProposalToIntent'.
6. Atomically write the encoded intent JSON to @--out@
   via 'writeFileAtomic' (temp file in the same
   directory + 'renameFile').

Any 'GovernanceWithdrawalInitError' is printed to stderr
with exit code 3.

The deposit-aware wallet-shortfall floor is computed
from the chain pparams via 'extractDepositComponents';
the two locally-named constants
'proposalVoteOutputCoinLovelace' and
'proposalEstimatedFeeLovelace' fill in the remaining
'DepositComponents' slots.
-}
runProposal :: GlobalOpts -> ProposalOpts -> IO ()
runProposal g po = do
    let cf = poCommon po
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortProposal (T.pack e)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortProposal
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            GovernanceWithdrawalInitProposalAnswers
                { gwipaValidityHours = cfValidityHours cf
                , gwipaFundingSeedTxIn = cfFundingSeedTxIn cf
                , gwipaFundingStakeKeyHash = poFundingStakeKeyHash po
                , gwipaVoterKeyHash = poVoterKeyHash po
                , gwipaWithdrawalAmountLovelace =
                    poWithdrawalAmountLovelace po
                , gwipaAnchorUrl = poAnchorUrl po
                , gwipaAnchorHash = poAnchorHash po
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        let input =
                GovernanceWithdrawalInitResolverInput
                    { gwiriNetwork = networkName
                    , gwiriWalletAddrBech32 = cfWalletAddr cf
                    , gwiriRegistryPath = cfRegistry cf
                    , gwiriAccountsPath = cfStakeRewardAccounts cf
                    , gwiriValidityHours = cfValidityHours cf
                    }
            renv =
                GovernanceWithdrawalInitResolverEnv
                    { gwireQueryWalletUtxos = queryFlat backend
                    , gwireComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    , gwireReadRegistry = readRegistrySafely
                    , gwireReadAccounts = readAccountsSafely
                    , gwireDepositComponents =
                        -- Nested withLiveContext: pparams are
                        -- ONLY queried if and when the resolver
                        -- reaches the deposit-aware shortfall
                        -- check, AFTER the devnet guard,
                        -- registry parse, accounts parse, and
                        -- cross-validation have all passed.
                        -- The Set.empty argument means no UTxO
                        -- acquisition — the wizard's job is to
                        -- PRODUCE the intent JSON, not to build
                        -- the tx; the actual tx build happens
                        -- at `tx-build --intent`.
                        withLiveContext
                            (networkFromMagic (goNetworkMagic g))
                            backend
                            Set.empty
                            (pure . extractDepositComponents . ccPParams)
                    }
        er <- resolveGovernanceWithdrawalInitProposal renv input
        env <- case er of
            Left e ->
                abortProposal
                    ("resolve: " <> T.pack (show e))
            Right e -> pure e
        intent <-
            case governanceWithdrawalInitProposalToIntent
                env
                answers of
                Left te ->
                    abortProposal
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        writeFileAtomic (cfOut cf) (encodeSomeTreasuryIntent intent)
  where
    unwrapSlot (SlotNo s) = s

{- | Write @bytes@ to @path@ atomically: open a temp file
in the same directory, write the contents there, then
rename onto the target. If the rename succeeds the
target is replaced atomically (POSIX guarantee on
same-filesystem renames); if any step throws, the temp
file is cleaned up.

Mirrors the pattern 'Amaru.Treasury.Cli.Vault' and
'Amaru.Treasury.Cli.Witness' use for their secret/output
writes; kept local here because no shared helper exists
yet at the CLI layer.
-}
writeFileAtomic :: FilePath -> BSL.ByteString -> IO ()
writeFileAtomic path bytes = do
    let dir = takeDirectory path
    (tmp, handle) <- openTempFile dir ".gov-init-proposal.tmp"
    hClose handle
    (BSL.writeFile tmp bytes >> renameFile tmp path)
        `onException` ignoreRemove tmp

ignoreRemove :: FilePath -> IO ()
ignoreRemove path =
    removeFile path `catch` \(_ :: IOException) -> pure ()

abortProposal :: Text -> IO a
abortProposal msg = do
    hPutStrLn
        stderr
        ( "governance-withdrawal-init-wizard proposal: "
            <> T.unpack msg
        )
    exitWith (ExitFailure 3)

{- | 'readDevnetGovernanceWithdrawalRegistry' is implemented
as @eitherDecodeFileStrict@, which throws on missing files
rather than returning @Left@. The resolver contract maps
ANY underlying registry-file failure (missing,
unparseable, wrong phase, wrong network) to a single
'GovernanceWithdrawalInitRegistryReadError', so the CLI
bridge catches the IOException and surfaces its message
via @Left@.
-}
readRegistrySafely
    :: FilePath
    -> IO (Either String DevnetGovernanceWithdrawalRegistry)
readRegistrySafely path =
    try (readDevnetGovernanceWithdrawalRegistry path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right inner -> pure inner

{- | Same wrapping pattern as 'readRegistrySafely' for the
  stake-reward-accounts artifact.
-}
readAccountsSafely
    :: FilePath
    -> IO (Either String DevnetGovernanceStakeRewardAccounts)
readAccountsSafely path =
    try (readDevnetGovernanceStakeRewardAccounts path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right inner -> pure inner

-- ----------------------------------------------------
-- Live materialization runner
-- ----------------------------------------------------

{- | Live @materialization@ path. Mirrors 'runProposal'
field-by-field except that:

* the resolver consumes
  'GovernanceWithdrawalInitMaterializationResolverEnv'
  whose @gwimreFloorComponents@ is a pure value
  ('defaultMaterializationFloorComponents') — no
  pparams query is needed, because the materialization
  floor is operator-diagnostic headroom, not a chain-
  derived deposit set.
* the translator is
  'governanceWithdrawalInitMaterializationToIntent', which
  extracts @treasuryRewardAccountHash@,
  @treasuryAddress@, @treasuryRefTxIn@, @registryRefTxIn@
  from the parsed registry and the operator-typed
  @rewardsLovelace@ from the answers.

Devnet network guard fires as the FIRST check (inside the
resolver), before any artifact parse, before the wallet
query, and before the upper-bound query.
-}
runMaterialization :: GlobalOpts -> MaterializationOpts -> IO ()
runMaterialization g mo = do
    let cf = moCommon mo
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortMaterialization (T.pack e)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortMaterialization
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            GovernanceWithdrawalInitMaterializationAnswers
                { gwimaValidityHours = cfValidityHours cf
                , gwimaFundingSeedTxIn = cfFundingSeedTxIn cf
                , gwimaRewardsLovelace = moRewardsLovelace mo
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        let input =
                GovernanceWithdrawalInitResolverInput
                    { gwiriNetwork = networkName
                    , gwiriWalletAddrBech32 = cfWalletAddr cf
                    , gwiriRegistryPath = cfRegistry cf
                    , gwiriAccountsPath = cfStakeRewardAccounts cf
                    , gwiriValidityHours = cfValidityHours cf
                    }
            renv =
                GovernanceWithdrawalInitMaterializationResolverEnv
                    { gwimreQueryWalletUtxos = queryFlat backend
                    , gwimreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    , gwimreReadRegistry = readRegistrySafely
                    , gwimreReadAccounts = readAccountsSafely
                    , gwimreFloorComponents =
                        defaultMaterializationFloorComponents
                    }
        er <- resolveGovernanceWithdrawalInitMaterialization renv input
        env <- case er of
            Left e ->
                abortMaterialization
                    ("resolve: " <> T.pack (show e))
            Right e -> pure e
        intent <-
            case governanceWithdrawalInitMaterializationToIntent
                env
                answers of
                Left te ->
                    abortMaterialization
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        writeFileAtomic (cfOut cf) (encodeSomeTreasuryIntent intent)
  where
    unwrapSlot (SlotNo s) = s

abortMaterialization :: Text -> IO a
abortMaterialization msg = do
    hPutStrLn
        stderr
        ( "governance-withdrawal-init-wizard materialization: "
            <> T.unpack msg
        )
    exitWith (ExitFailure 3)
