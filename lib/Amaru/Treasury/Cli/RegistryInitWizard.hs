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
    , SeedSplitOpts (..)
    , MintOpts (..)
    , ReferenceScriptsOpts (..)

      -- * Parser
    , registryInitWizardOptsP

      -- * Runner + --out checks
    , runRegistryInitWizard
    , validateOutPath
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

import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , resolveNetworkName
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
    ( RegistryInitError (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitResolverInput (..)
    , RegistryInitSeedSplitAnswers (..)
    , registryInitMintToIntent
    , registryInitReferenceScriptsToIntent
    , registryInitSeedSplitToIntent
    , resolveRegistryInitSeedSplit
    )
import Amaru.Treasury.Tx.SwapWizard
    ( registryViewFromVerified
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
        er <- resolveRegistryInitSeedSplit renv input
        env <- case er of
            Left e ->
                abortSeedSplit
                    ("resolve: " <> T.pack (show e))
            Right e -> pure e
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
        er <- resolveRegistryInitSeedSplit renv input
        env <- case er of
            Left e ->
                abortMint
                    ("resolve: " <> T.pack (show e))
            Right e -> pure e
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
        er <- resolveRegistryInitSeedSplit renv input
        env <- case er of
            Left e ->
                abortReferenceScripts
                    ("resolve: " <> T.pack (show e))
            Right e -> pure e
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
-- Bootstrap runner branches (#175 Slice 1)
-- ----------------------------------------------------

{- | Bootstrap @seed-split@ branch (#175 Slice 1).

Slice 1 only establishes the explicit verified/bootstrap split:
the bootstrap branches deliberately do not call 'verifyRegistry'
and emit a clear not-implemented error pointing to Slice 2, where
the DevNet-only bootstrap resolver and the three bootstrap intent
emissions land.
-}
runSeedSplitBootstrap :: GlobalOpts -> CommonFlags -> IO ()
runSeedSplitBootstrap _g _cf =
    abortSeedSplit
        "bootstrap mode: intent emission is not implemented yet"

{- | Bootstrap @mint@ branch (#175 Slice 1). See
'runSeedSplitBootstrap'.
-}
runMintBootstrap :: GlobalOpts -> MintOpts -> IO ()
runMintBootstrap _g _mintOpts =
    abortMint
        "bootstrap mode: intent emission is not implemented yet"

{- | Bootstrap @reference-scripts@ branch (#175 Slice 1). See
'runSeedSplitBootstrap'.
-}
runReferenceScriptsBootstrap
    :: GlobalOpts -> ReferenceScriptsOpts -> IO ()
runReferenceScriptsBootstrap _g _rsOpts =
    abortReferenceScripts
        "bootstrap mode: intent emission is not implemented yet"
