{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.RegistryInitWizard
Description : CLI parser and runner for the registry-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of #158 shipped the discriminated parser and an
@--out@ pre-flight check. Slice 2 wires the live @seed-split@
runner: build a 'RegistryInitResolverInput' from CLI options,
build a 'RegistryInitResolverEnv' from the provider (mirroring
'Amaru.Treasury.Cli.WithdrawWizard.providerToWithdrawResolverEnv'),
resolve the env, translate to 'SomeTreasuryIntent', and write
the encoded JSON to @--out@. Slice 3 wires the @mint@ arm on
the same shape: the resolver is shared (the chain-derived
seed-split env is exactly what the mint translation also
needs), and the three operator-typed inter-tx values
(@--scopes-seed-txin@, @--registry-seed-txin@,
@--owner-key-hash@) are passed alongside via the typed
'RegistryInitMintAnswers'. Slice 4 wires the
@reference-scripts@ arm on the same shape: the three
operator-typed TxIns (@--scopes-seed-txin@,
@--registry-seed-txin@, @--funding-seed-txin@) are baked
verbatim by 'registryInitReferenceScriptsToIntent'. All
three subcommands are now functional.

The parser reuses 'Amaru.Treasury.LedgerParse.txInFromText' and
'Amaru.Treasury.LedgerParse.keyHashFromHex' via
'Options.Applicative.eitherReader'; there is no local hex-28 or
@txid#ix@ parser.
-}
module Amaru.Treasury.Cli.RegistryInitWizard
    ( -- * Options
      RegistryInitWizardOpts (..)
    , CommonFlags (..)
    , SeedSplitOpts (..)
    , MintOpts (..)
    , ReferenceScriptsOpts (..)
    , WriteArtifactsOpts (..)

      -- * Parser
    , registryInitWizardOptsP

      -- * Runner + --out checks
    , runRegistryInitWizard
    , validateOutPath

      -- * Input control (#184 — Slice 5)
    , validateRegistryInitWizardInputControl
    ) where

import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
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
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO (hPrint, hPutStrLn, stderr)

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , resolveNetworkName
    )
import Amaru.Treasury.Devnet.RegistryInit
    ( BootstrapArtifactArgs (..)
    , runBootstrapWriter
    )
import Amaru.Treasury.IntentJSON
    ( encodeSomeTreasuryIntent
    )
import Amaru.Treasury.LedgerParse
    ( keyHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.RegistryInitWizard
    ( InputControlOutcome (..)
    , RegistryInitBootstrapInput (..)
    , RegistryInitError (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitResolverInput (..)
    , RegistryInitSeedSplitAnswers (..)
    , registryInitMintToIntent
    , registryInitReferenceScriptsToIntent
    , registryInitSeedSplitToIntent
    , renderRegistryInitExclusionLogLine
    , renderRegistryInitWalletShortfallWithExcludes
    , resolveRegistryInitBootstrapIC
    , resolveRegistryInitSeedSplitIC
    )
import Amaru.Treasury.Tx.SwapWizard
    ( registryViewFromVerified
    )
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , InputControlError
    , excludeUtxoP
    , extraTxInP
    , outRefText
    , renderInputControlError
    , validateInputControl
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
    , cfExcludeSet :: !ExclusionSet
    -- ^ Operator-supplied @--exclude-utxo@ refs in flag order (#184).
    , cfForcedSet :: !ForcedInclusionSet
    -- ^ Operator-supplied @--extra-tx-in@ refs in flag order (#184).
    , cfBootstrap :: !Bool
    -- ^ Slice 1 of #175: when 'True', dispatch to the bootstrap
    -- runner branch (DevNet-only, no on-chain registry metadata
    -- expected). When 'False', the existing verified path runs
    -- and 'verifyRegistry' is called before any intent emission.
    -- Bootstrap-mode intent emission lands in Slice 2.
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

-- | Options for the @write-artifacts@ sub-action.
data WriteArtifactsOpts = WriteArtifactsOpts
    { waRunDir :: !FilePath
    , waSeedSplitTxId :: !Text
    , waRegistryMintTxId :: !Text
    , waReferenceScriptsTxId :: !Text
    , waScopesSeedTxIn :: !Text
    , waRegistrySeedTxIn :: !Text
    , waOwnerKeyHash :: !Text
    }
    deriving stock (Eq, Show)

-- | Discriminated union dispatched by the runner.
data RegistryInitWizardOpts
    = RegistryInitSeedSplitOpts !SeedSplitOpts
    | RegistryInitMintOpts !MintOpts
    | RegistryInitReferenceScriptsOpts !ReferenceScriptsOpts
    | RegistryInitWriteArtifactsOpts !WriteArtifactsOpts
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
            <> command
                "write-artifacts"
                ( info
                    (RegistryInitWriteArtifactsOpts <$> writeArtifactsOptsP)
                    ( progDesc
                        "Write DevNet registry-init artifacts from submitted bootstrap transaction ids"
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

writeArtifactsOptsP :: Parser WriteArtifactsOpts
writeArtifactsOptsP =
    WriteArtifactsOpts
        <$> strOption
            ( long "run-dir"
                <> metavar "DIR"
                <> help "DevNet run directory where registry-init artifacts are written"
            )
        <*> option
            txIdTextReader
            ( long "seed-split-txid"
                <> metavar "TXID"
                <> help "Submitted seed-split transaction id"
            )
        <*> option
            txIdTextReader
            ( long "registry-mint-txid"
                <> metavar "TXID"
                <> help "Submitted registry mint transaction id"
            )
        <*> option
            txIdTextReader
            ( long "reference-scripts-txid"
                <> metavar "TXID"
                <> help "Submitted reference-scripts transaction id"
            )
        <*> option
            txInTextReader
            ( long "scopes-seed-txin"
                <> metavar "TXID#IX"
                <> help "Scopes seed TxIn produced by seed-split"
            )
        <*> option
            txInTextReader
            ( long "registry-seed-txin"
                <> metavar "TXID#IX"
                <> help "Registry seed TxIn produced by seed-split"
            )
        <*> option
            keyHashTextReader
            ( long "owner-key-hash"
                <> metavar "HEX28"
                <> help "28-byte scope owner key hash"
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
        <*> (ExclusionSet <$> excludeUtxoP)
        <*> (ForcedInclusionSet <$> extraTxInP)
        <*> flag
            False
            True
            ( long "bootstrap"
                <> help
                    "DevNet-only: run in fresh-chain bootstrap mode \
                    \(no on-chain registry metadata required)"
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

txIdTextReader :: ReadM Text
txIdTextReader =
    eitherReader $ \raw -> do
        let text = T.pack raw
        _ <- txInFromText (text <> "#0")
        pure text

txInTextReader :: ReadM Text
txInTextReader =
    eitherReader $ \raw -> do
        let text = T.pack raw
        _ <- txInFromText text
        pure text

keyHashTextReader :: ReadM Text
keyHashTextReader =
    eitherReader $ \raw -> do
        let text = T.pack raw
        _ <- keyHashFromHex text
        pure text

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
-- Input-control helpers (#184 Slice 5)
-- ----------------------------------------------------

{- | Pre-flight check for @--exclude-utxo@ / @--extra-tx-in@
contradictions on the @registry-init-wizard@ subcommand
family. Run before any chain query so the contradiction
exits fast.
-}
validateRegistryInitWizardInputControl
    :: CommonFlags -> Either InputControlError ()
validateRegistryInitWizardInputControl cf =
    validateInputControl (cfExcludeSet cf) (cfForcedSet cf)

{- | Render the FR-008 / FR-009 resolver errors introduced
by #184 onto stderr-friendly text. Falls back to @show@ for
all other 'RegistryInitError' variants.
-}
renderRegistryInitResolverError
    :: RegistryInitError -> Text
renderRegistryInitResolverError
    (RegistryInitResolverExtraTxInNotOnWallet refs) =
        "extra input not found on wallet: "
            <> T.intercalate ", " (map outRefText refs)
renderRegistryInitResolverError
    (RegistryInitResolverWalletShortfallWithExcludes avail required refs) =
        renderRegistryInitWalletShortfallWithExcludes
            ( "wallet shortfall available="
                <> T.pack (show avail)
                <> " required="
                <> T.pack (show required)
            )
            refs
renderRegistryInitResolverError e =
    "resolve: " <> T.pack (show e)

{- | Emit one stderr log line per excluded ref in
exclusion-set input order. Hits carry pool attribution
(@[wallet]@); inert refs (operator-supplied excludes that
did not match any candidate) are logged with @[absent]@ so
the operator sees their @--exclude-utxo@ was applied.
-}
emitRegistryInitExclusionLog
    :: Text -> InputControlOutcome -> IO ()
emitRegistryInitExclusionLog prefix outcome = do
    mapM_
        ( \(ref, pool) ->
            hPutStrLn
                stderr
                ( T.unpack
                    ( renderRegistryInitExclusionLogLine
                        prefix
                        ref
                        pool
                    )
                )
        )
        (icoHits outcome)
    mapM_
        ( \ref ->
            hPutStrLn
                stderr
                ( T.unpack
                    ( prefix
                        <> ": excluded utxo "
                        <> outRefText ref
                        <> " (operator-supplied) [absent]"
                    )
                )
        )
        (icoInert outcome)

-- ----------------------------------------------------
-- Runner
-- ----------------------------------------------------

{- | Top-level dispatcher.

Performs the @--out@ pre-flight check first; on failure
prints the typed 'RegistryInitError' to stderr and exits
with code 2. Each of the three sub-actions then runs its
live path (resolve → translate → encode → write).
-}
runRegistryInitWizard
    :: GlobalOpts -> RegistryInitWizardOpts -> IO ()
runRegistryInitWizard g cmd = case cmd of
    RegistryInitSeedSplitOpts (SeedSplitOpts cf) -> do
        guardOut (cfOut cf) (cfForce cf)
        if cfBootstrap cf
            then runSeedSplitBootstrap g cf
            else runSeedSplitVerified g cf
    RegistryInitMintOpts mintOpts -> do
        let cf = mCommon mintOpts
        guardOut (cfOut cf) (cfForce cf)
        if cfBootstrap cf
            then runMintBootstrap g mintOpts
            else runMintVerified g mintOpts
    RegistryInitReferenceScriptsOpts rsOpts -> do
        let cf = rsCommon rsOpts
        guardOut (cfOut cf) (cfForce cf)
        if cfBootstrap cf
            then runReferenceScriptsBootstrap g rsOpts
            else runReferenceScriptsVerified g rsOpts
    RegistryInitWriteArtifactsOpts waOpts ->
        runWriteArtifacts g waOpts
  where
    guardOut path force = do
        r <- validateOutPath path force
        case r of
            Right () -> pure ()
            Left e -> do
                hPrint stderr e
                exitWith (ExitFailure 2)

-- ----------------------------------------------------
-- Live seed-split runner
-- ----------------------------------------------------

{- | Live @seed-split@ path: resolve the chain-derived
environment, translate to a 'SomeTreasuryIntent', encode
and write to @--out@. Any 'RegistryInitError' is printed
to stderr and produces exit code 3.

Network mismatch surfaces twice: once via the resolver's
'RegistryInitNonDevnetNetwork' guard for @--network@ values
other than @"devnet"@, and once via the pure translation if
the registry view ends up keyed for an unsupported network.
-}
runSeedSplitVerified :: GlobalOpts -> CommonFlags -> IO ()
runSeedSplitVerified g cf = do
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortSeedSplit (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortSeedSplit (T.pack e)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortSeedSplit
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitSeedSplitAnswers
                { risScope = cfScope cf
                , risValidityHours = cfValidityHours cf
                , risDescription = cfDescription cf
                , risJustification = cfJustification cf
                , risDestinationLabel = cfDestinationLabel cf
                , risEvent = cfEvent cf
                , risLabel = cfLabel cf
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        verified <-
            verifyRegistry
                backend
                (cfMetadataPath cf)
                (Set.singleton (cfScope cf))
        rv <- case verified of
            Left e ->
                abortSeedSplit
                    ("verify: " <> T.pack (show e))
            Right registry ->
                case registryViewFromVerified
                    (cfScope cf)
                    registry of
                    Left e ->
                        abortSeedSplit
                            ("project: " <> T.pack (show e))
                    Right view -> pure view
        let input =
                RegistryInitResolverInput
                    { wriNetwork = networkName
                    , wriWalletAddrBech32 = cfWalletAddr cf
                    , wriScope = cfScope cf
                    , wriRegistry = rv
                    , wriValidityHours = cfValidityHours cf
                    }
            renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitSeedSplitIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortSeedSplit (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard seed-split"
                    outcome
                pure e
        intent <-
            case registryInitSeedSplitToIntent env answers of
                Left te ->
                    abortSeedSplit
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        let bytes = encodeSomeTreasuryIntent intent
        BSL.writeFile (cfOut cf) bytes
  where
    unwrapSlot (SlotNo s) = s

abortSeedSplit :: Text -> IO a
abortSeedSplit msg = do
    hPutStrLn stderr ("registry-init-wizard seed-split: " <> T.unpack msg)
    exitWith (ExitFailure 3)

-- ----------------------------------------------------
-- Live mint runner
-- ----------------------------------------------------

{- | Live @mint@ path: build a 'RegistryInitResolverInput'
from the CLI options, reuse the seed-split resolver (the
chain-derived environment is identical), and translate to a
'SomeTreasuryIntent' via 'registryInitMintToIntent'. The
three operator-typed values — @--scopes-seed-txin@,
@--registry-seed-txin@, @--owner-key-hash@ — are baked
verbatim into the intent's payload by the pure translator.

The resolver fires the devnet network guard before any chain
query; any 'RegistryInitError' from the resolver or the
translation is printed to stderr with exit code 3.
-}
runMintVerified :: GlobalOpts -> MintOpts -> IO ()
runMintVerified g mintOpts = do
    let cf = mCommon mintOpts
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortMint (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortMint (T.pack e)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortMint
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitMintAnswers
                { rimScope = cfScope cf
                , rimValidityHours = cfValidityHours cf
                , rimDescription = cfDescription cf
                , rimJustification = cfJustification cf
                , rimDestinationLabel = cfDestinationLabel cf
                , rimEvent = cfEvent cf
                , rimLabel = cfLabel cf
                , rimScopesSeedTxIn = mScopesSeedTxIn mintOpts
                , rimRegistrySeedTxIn = mRegistrySeedTxIn mintOpts
                , rimOwnerKeyHash = mOwnerKeyHash mintOpts
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        verified <-
            verifyRegistry
                backend
                (cfMetadataPath cf)
                (Set.singleton (cfScope cf))
        rv <- case verified of
            Left e ->
                abortMint
                    ("verify: " <> T.pack (show e))
            Right registry ->
                case registryViewFromVerified
                    (cfScope cf)
                    registry of
                    Left e ->
                        abortMint
                            ("project: " <> T.pack (show e))
                    Right view -> pure view
        let input =
                RegistryInitResolverInput
                    { wriNetwork = networkName
                    , wriWalletAddrBech32 = cfWalletAddr cf
                    , wriScope = cfScope cf
                    , wriRegistry = rv
                    , wriValidityHours = cfValidityHours cf
                    }
            renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitSeedSplitIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortMint (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard mint"
                    outcome
                pure e
        intent <-
            case registryInitMintToIntent env answers of
                Left te ->
                    abortMint
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        let bytes = encodeSomeTreasuryIntent intent
        BSL.writeFile (cfOut cf) bytes
  where
    unwrapSlot (SlotNo s) = s

abortMint :: Text -> IO a
abortMint msg = do
    hPutStrLn stderr ("registry-init-wizard mint: " <> T.unpack msg)
    exitWith (ExitFailure 3)

-- ----------------------------------------------------
-- Live reference-scripts runner
-- ----------------------------------------------------

{- | Live @reference-scripts@ path: build a
'RegistryInitResolverInput' from the CLI options, reuse the
seed-split resolver (the chain-derived environment is
identical), and translate to a 'SomeTreasuryIntent' via
'registryInitReferenceScriptsToIntent'. The three
operator-typed values — @--scopes-seed-txin@,
@--registry-seed-txin@, @--funding-seed-txin@ — are baked
verbatim into the intent by the pure translator (the two
seed TxIns go into the payload; the funding seed TxIn goes
into the wallet block).

The resolver fires the devnet network guard before any chain
query; any 'RegistryInitError' from the resolver or the
translation is printed to stderr with exit code 3.
-}
runReferenceScriptsVerified
    :: GlobalOpts -> ReferenceScriptsOpts -> IO ()
runReferenceScriptsVerified g rsOpts = do
    let cf = rsCommon rsOpts
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortReferenceScripts (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortReferenceScripts (T.pack e)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortReferenceScripts
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitReferenceScriptsAnswers
                { rirScope = cfScope cf
                , rirValidityHours = cfValidityHours cf
                , rirDescription = cfDescription cf
                , rirJustification = cfJustification cf
                , rirDestinationLabel = cfDestinationLabel cf
                , rirEvent = cfEvent cf
                , rirLabel = cfLabel cf
                , rirScopesSeedTxIn = rsScopesSeedTxIn rsOpts
                , rirRegistrySeedTxIn = rsRegistrySeedTxIn rsOpts
                , rirFundingSeedTxIn = rsFundingSeedTxIn rsOpts
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        verified <-
            verifyRegistry
                backend
                (cfMetadataPath cf)
                (Set.singleton (cfScope cf))
        rv <- case verified of
            Left e ->
                abortReferenceScripts
                    ("verify: " <> T.pack (show e))
            Right registry ->
                case registryViewFromVerified
                    (cfScope cf)
                    registry of
                    Left e ->
                        abortReferenceScripts
                            ("project: " <> T.pack (show e))
                    Right view -> pure view
        let input =
                RegistryInitResolverInput
                    { wriNetwork = networkName
                    , wriWalletAddrBech32 = cfWalletAddr cf
                    , wriScope = cfScope cf
                    , wriRegistry = rv
                    , wriValidityHours = cfValidityHours cf
                    }
            renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitSeedSplitIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortReferenceScripts
                    (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard reference-scripts"
                    outcome
                pure e
        intent <-
            case registryInitReferenceScriptsToIntent env answers of
                Left te ->
                    abortReferenceScripts
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        let bytes = encodeSomeTreasuryIntent intent
        BSL.writeFile (cfOut cf) bytes
  where
    unwrapSlot (SlotNo s) = s

abortReferenceScripts :: Text -> IO a
abortReferenceScripts msg = do
    hPutStrLn
        stderr
        ( "registry-init-wizard reference-scripts: "
            <> T.unpack msg
        )
    exitWith (ExitFailure 3)

-- ----------------------------------------------------
-- Bootstrap runner branches (#175 Slice 2)
-- ----------------------------------------------------

{- | Bootstrap @seed-split@ branch (#175 Slice 2).

DevNet-only: resolves the network first and fails closed for
non-@devnet@ networks BEFORE opening the node backend,
querying chain, or writing the @--out@ file. On devnet it
queries the wallet UTxOs and upper-bound slot through the
same backend helpers as verified mode but skips
'verifyRegistry'. The resolved 'RegistryInitEnv' carries a
skeleton registry projection; the pure translator stamps it
into the intent for downstream encoding. The build-side
translators do not consume those placeholder anchors. #175
Slice 3 ships the artifact writer that records the REAL
anchors from submitted tx ids.
-}
runSeedSplitBootstrap :: GlobalOpts -> CommonFlags -> IO ()
runSeedSplitBootstrap g cf = do
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortSeedSplit (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortSeedSplit (T.pack e)
    case networkName of
        "devnet" -> pure ()
        other ->
            abortSeedSplit
                ("bootstrap mode is devnet-only, got " <> other)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortSeedSplit
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitSeedSplitAnswers
                { risScope = cfScope cf
                , risValidityHours = cfValidityHours cf
                , risDescription = cfDescription cf
                , risJustification = cfJustification cf
                , risDestinationLabel = cfDestinationLabel cf
                , risEvent = cfEvent cf
                , risLabel = cfLabel cf
                }
        input =
            RegistryInitBootstrapInput
                { wbiNetwork = networkName
                , wbiWalletAddrBech32 = cfWalletAddr cf
                , wbiScope = cfScope cf
                , wbiValidityHours = cfValidityHours cf
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        let renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitBootstrapIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortSeedSplit
                    (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard seed-split (bootstrap)"
                    outcome
                pure e
        intent <-
            case registryInitSeedSplitToIntent env answers of
                Left te ->
                    abortSeedSplit
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        BSL.writeFile
            (cfOut cf)
            (encodeSomeTreasuryIntent intent)
  where
    unwrapSlot (SlotNo s) = s

{- | Bootstrap @mint@ branch (#175 Slice 2). Reuses the
bootstrap resolver; the three operator-typed values
(@--scopes-seed-txin@, @--registry-seed-txin@,
@--owner-key-hash@) are baked verbatim by the pure
translator.
-}
runMintBootstrap :: GlobalOpts -> MintOpts -> IO ()
runMintBootstrap g mintOpts = do
    let cf = mCommon mintOpts
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortMint (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortMint (T.pack e)
    case networkName of
        "devnet" -> pure ()
        other ->
            abortMint
                ("bootstrap mode is devnet-only, got " <> other)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortMint
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitMintAnswers
                { rimScope = cfScope cf
                , rimValidityHours = cfValidityHours cf
                , rimDescription = cfDescription cf
                , rimJustification = cfJustification cf
                , rimDestinationLabel = cfDestinationLabel cf
                , rimEvent = cfEvent cf
                , rimLabel = cfLabel cf
                , rimScopesSeedTxIn = mScopesSeedTxIn mintOpts
                , rimRegistrySeedTxIn = mRegistrySeedTxIn mintOpts
                , rimOwnerKeyHash = mOwnerKeyHash mintOpts
                }
        input =
            RegistryInitBootstrapInput
                { wbiNetwork = networkName
                , wbiWalletAddrBech32 = cfWalletAddr cf
                , wbiScope = cfScope cf
                , wbiValidityHours = cfValidityHours cf
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        let renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitBootstrapIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortMint (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard mint (bootstrap)"
                    outcome
                pure e
        intent <-
            case registryInitMintToIntent env answers of
                Left te ->
                    abortMint
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        BSL.writeFile
            (cfOut cf)
            (encodeSomeTreasuryIntent intent)
  where
    unwrapSlot (SlotNo s) = s

{- | Bootstrap @reference-scripts@ branch (#175 Slice 2).
Reuses the bootstrap resolver. The translator overrides the
wallet block's @txIn@ with the operator-typed
@--funding-seed-txin@ during JSON construction (same as the
verified path).
-}
runReferenceScriptsBootstrap
    :: GlobalOpts -> ReferenceScriptsOpts -> IO ()
runReferenceScriptsBootstrap g rsOpts = do
    let cf = rsCommon rsOpts
    case validateRegistryInitWizardInputControl cf of
        Right () -> pure ()
        Left ce ->
            abortReferenceScripts (renderInputControlError ce)
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortReferenceScripts (T.pack e)
    case networkName of
        "devnet" -> pure ()
        other ->
            abortReferenceScripts
                ("bootstrap mode is devnet-only, got " <> other)
    socket <- case goSocketPath g of
        Just s -> pure s
        Nothing ->
            abortReferenceScripts
                "--node-socket / CARDANO_NODE_SOCKET_PATH is required"
    let answers =
            RegistryInitReferenceScriptsAnswers
                { rirScope = cfScope cf
                , rirValidityHours = cfValidityHours cf
                , rirDescription = cfDescription cf
                , rirJustification = cfJustification cf
                , rirDestinationLabel = cfDestinationLabel cf
                , rirEvent = cfEvent cf
                , rirLabel = cfLabel cf
                , rirScopesSeedTxIn = rsScopesSeedTxIn rsOpts
                , rirRegistrySeedTxIn = rsRegistrySeedTxIn rsOpts
                , rirFundingSeedTxIn = rsFundingSeedTxIn rsOpts
                }
        input =
            RegistryInitBootstrapInput
                { wbiNetwork = networkName
                , wbiWalletAddrBech32 = cfWalletAddr cf
                , wbiScope = cfScope cf
                , wbiValidityHours = cfValidityHours cf
                }
    withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
        let renv =
                RegistryInitResolverEnv
                    { wreQueryWalletUtxos = queryFlat backend
                    , wreComputeUpperBound = \choice -> do
                        r <- queryUpperBoundSlot backend choice
                        pure (fmap unwrapSlot r)
                    }
        er <-
            resolveRegistryInitBootstrapIC
                renv
                (cfExcludeSet cf)
                (cfForcedSet cf)
                input
        env <- case er of
            Left e ->
                abortReferenceScripts
                    (renderRegistryInitResolverError e)
            Right (e, outcome) -> do
                emitRegistryInitExclusionLog
                    "registry-init-wizard reference-scripts (bootstrap)"
                    outcome
                pure e
        intent <-
            case registryInitReferenceScriptsToIntent env answers of
                Left te ->
                    abortReferenceScripts
                        ("translate: " <> T.pack (show te))
                Right i -> pure i
        BSL.writeFile
            (cfOut cf)
            (encodeSomeTreasuryIntent intent)
  where
    unwrapSlot (SlotNo s) = s

-- ----------------------------------------------------
-- Bootstrap artifact writer (#175 Slice 3)
-- ----------------------------------------------------

runWriteArtifacts :: GlobalOpts -> WriteArtifactsOpts -> IO ()
runWriteArtifacts g waOpts = do
    networkName <- case resolveNetworkName g of
        Right t -> pure t
        Left e -> abortWriteArtifacts (T.pack e)
    let NetworkMagic magic =
            goNetworkMagic g
        args =
            BootstrapArtifactArgs
                { baaSeedSplitTxId = waSeedSplitTxId waOpts
                , baaRegistryMintTxId = waRegistryMintTxId waOpts
                , baaReferenceScriptsTxId =
                    waReferenceScriptsTxId waOpts
                , baaScopesSeedTxIn = waScopesSeedTxIn waOpts
                , baaRegistrySeedTxIn = waRegistrySeedTxIn waOpts
                , baaOwnerKeyHash = waOwnerKeyHash waOpts
                , baaNetwork = Testnet
                }
    runBootstrapWriter
        networkName
        (fromIntegral magic)
        (waRunDir waOpts)
        args
        >>= \case
            Right () -> pure ()
            Left e -> abortWriteArtifacts (T.pack e)

abortWriteArtifacts :: Text -> IO a
abortWriteArtifacts msg = do
    hPutStrLn
        stderr
        ("registry-init-wizard write-artifacts: " <> T.unpack msg)
    exitWith (ExitFailure 3)
