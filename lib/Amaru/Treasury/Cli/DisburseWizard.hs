{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Amaru.Treasury.Cli.DisburseWizard
Description : CLI parser and runner for disburse-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Keeps the disburse wizard's command-line surface and IO
runner out of the top-level executable. 'Main' owns only
command dispatch; this module owns the disburse-specific
parser, provider adapter, tracing, registry projection,
and intent writing.
-}
module Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardOpts (..)
    , ContingencyDisburseOpts (..)
    , disburseWizardOptsP
    , contingencyDisburseOptsP
    , runDisburseWizard
    , runContingencyDisburse
    ) where

import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit, toLower)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16)

import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (ExitCode (..), exitWith)

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , queryValues
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Derive (derivedScopesNftPolicy)
import Amaru.Treasury.Registry.Metadata
    ( ScriptDeployment (..)
    , TreasuryEntry (..)
    , TxInRef (..)
    , UpstreamMetadata (..)
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Registry.Verify
    ( RegistryWalkError (..)
    , VerifiedRegistry (..)
    , VerifiedScope (..)
    , verifyRegistry
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Tx.DisburseWizard qualified as Disburse
import Amaru.Treasury.Tx.DisburseWizard.Trace qualified as DisburseTrace

{- | Flags for the @disburse-wizard@ subcommand.
Mirrors @specs/004-disburse-wizard/contracts/disburse-wizard-cli.md §1@.
-}
data DisburseWizardOpts = DisburseWizardOpts
    { dwOptsWalletAddr :: !Text
    , dwOptsMetadataPath :: !FilePath
    , dwOptsOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , dwOptsLog :: !(Maybe FilePath)
    -- ^ where to send 'DisburseWizardEvent' lines. 'Nothing' = stderr.
    , dwOptsScope :: !ScopeId
    , dwOptsUnit :: !Unit
    -- ^ defaults to USDM; pass @--unit ada@ for ADA disbursements.
    , dwOptsAmount :: !Integer
    -- ^ lovelace for ADA, smallest USDM unit for USDM.
    , dwOptsBeneficiaryAddr :: !Text
    , dwOptsValidityHours :: !(Maybe Word16)
    , dwOptsDescription :: !Text
    , dwOptsJustification :: !Text
    , dwOptsDestinationLabel :: !Text
    , dwOptsEvent :: !(Maybe Text)
    , dwOptsLabel :: !(Maybe Text)
    , dwOptsSigners :: ![Text]
    -- ^ accumulated extra-signer flags; empty = selected
    --   scope owner only.
    , dwOptsTreasuryTxIns :: ![TxIn]
    -- ^ optional treasury TxIn allow-list applied after querying
    --   the treasury address.
    }
    deriving stock (Eq, Show)

{- | Flags for the @contingency-disburse-wizard@ subcommand.
The command is intentionally narrower than @disburse-wizard@:
source scope is always @contingency@, the unit is always ADA,
and the destination is another treasury scope resolved from
verified metadata.
-}
data ContingencyDisburseOpts = ContingencyDisburseOpts
    { cdOptsWalletAddr :: !Text
    , cdOptsMetadataPath :: !FilePath
    , cdOptsOut :: !(Maybe FilePath)
    , cdOptsLog :: !(Maybe FilePath)
    , cdOptsDestinationScope :: !ScopeId
    , cdOptsAdaLovelace :: !Integer
    , cdOptsValidityHours :: !(Maybe Word16)
    , cdOptsDescription :: !Text
    , cdOptsJustification :: !Text
    }
    deriving stock (Eq, Show)

disburseWizardOptsP :: Parser DisburseWizardOpts
disburseWizardOptsP =
    DisburseWizardOpts
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
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Where to write intent.json (defaults to stdout)"
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
        <*> option
            ownedScopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> ( fromMaybe USDM
                <$> optional
                    ( option
                        unitReader
                        ( long "unit"
                            <> metavar "ada|usdm"
                            <> help
                                "Disbursement unit (defaults to usdm)"
                        )
                    )
            )
        <*> option
            auto
            ( long "amount"
                <> metavar "INT"
                <> help
                    "Amount in the unit's smallest denomination: lovelace for ADA, 1e-6 USDM for USDM"
            )
        <*> strOption
            ( long "beneficiary-addr"
                <> metavar "BECH32"
                <> help "Beneficiary address"
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
                    <> help
                        "Rationale label override (defaults Disburse <unit>)"
                )
            )
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> long "signer"
                    <> metavar "SCOPE|HEX"
                    <> help
                        "Repeat for each extra signer (scope name/alias or 28-byte hex)"
                )
            )
        <*> many
            ( option
                txInReader
                ( long "treasury-txin"
                    <> long "treasury-utxo"
                    <> metavar "TXIN"
                    <> help
                        "Restrict treasury selection to this TxIn. Repeatable."
                )
            )

contingencyDisburseOptsP :: Parser ContingencyDisburseOpts
contingencyDisburseOptsP =
    ContingencyDisburseOpts
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
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Where to write intent.json (defaults to stdout)"
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
        <*> option
            ownedScopeReader
            ( long "destination-scope"
                <> long "to-scope"
                <> metavar "NAME"
                <> help
                    "Destination treasury scope: core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> option
            adaReader
            ( long "ada"
                <> metavar "ADA"
                <> help
                    "ADA amount to move from contingency; decimals up to 6 places are accepted"
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

ownedScopeReader :: ReadM ScopeId
ownedScopeReader =
    eitherReader $ \raw -> do
        scope <- scopeFromText (T.pack (map toLower raw))
        case scope of
            Contingency ->
                Left
                    "contingency is the emergency source; choose one of core_development|ops_and_use_cases|network_compliance|middleware"
            _ -> Right scope

unitReader :: ReadM Unit
unitReader =
    eitherReader $ \s -> case map toLower s of
        "ada" -> Right ADA
        "usdm" -> Right USDM
        _ -> Left "expected ada or usdm"

adaReader :: ReadM Integer
adaReader =
    eitherReader (parseAdaToLovelace . T.pack)

txInReader :: ReadM TxIn
txInReader =
    eitherReader (txInFromText . T.pack)

parseAdaToLovelace :: Text -> Either String Integer
parseAdaToLovelace raw =
    case T.splitOn "." raw of
        [whole]
            | digits whole ->
                positive (decimalDigitsToInteger whole * 1_000_000)
        [whole, fractional]
            | (not (T.null whole) || not (T.null fractional))
                && digits whole
                && digits fractional
                && T.length fractional <= 6 ->
                let padded = fractional <> T.replicate (6 - T.length fractional) "0"
                    lovelace =
                        decimalDigitsToInteger whole * 1_000_000
                            + decimalDigitsToInteger padded
                in  positive lovelace
            | T.length fractional > 6 ->
                Left "ADA amount cannot have more than 6 decimal places"
        _ -> Left "expected a positive ADA decimal"
  where
    digits = T.all isDigit
    positive lovelace
        | lovelace > 0 = Right lovelace
        | otherwise = Left "ADA amount must be positive"

decimalDigitsToInteger :: Text -> Integer
decimalDigitsToInteger =
    T.foldl'
        (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0'))
        0

runDisburseWizard
    :: GlobalOpts
    -> DisburseWizardOpts
    -> IO ()
runDisburseWizard g DisburseWizardOpts{..} =
    runDisburseCommand
        "disburse-wizard"
        g
        dwOptsLog
        dwOptsMetadataPath
        dwOptsOut
        (Set.singleton dwOptsScope)
        dwOptsScope
        $ \networkName rv _verified ->
            let answers =
                    Disburse.DisburseAnswers
                        { Disburse.daScope = dwOptsScope
                        , Disburse.daUnit = dwOptsUnit
                        , Disburse.daAmount = dwOptsAmount
                        , Disburse.daBeneficiaryAddrBech32 =
                            dwOptsBeneficiaryAddr
                        , Disburse.daValidityHours =
                            dwOptsValidityHours
                        , Disburse.daRationale =
                            Disburse.RationaleAnswers
                                { Disburse.raDescription =
                                    dwOptsDescription
                                , Disburse.raJustification =
                                    dwOptsJustification
                                , Disburse.raDestinationLabel =
                                    dwOptsDestinationLabel
                                , Disburse.raEvent = dwOptsEvent
                                , Disburse.raLabel = dwOptsLabel
                                }
                        , Disburse.daExtraSigners = dwOptsSigners
                        }
                ri =
                    Disburse.ResolverInput
                        { Disburse.riNetwork = networkName
                        , Disburse.riWalletAddrBech32 =
                            dwOptsWalletAddr
                        , Disburse.riBeneficiaryAddrBech32 =
                            dwOptsBeneficiaryAddr
                        , Disburse.riScope = dwOptsScope
                        , Disburse.riUnit = dwOptsUnit
                        , Disburse.riAmount = dwOptsAmount
                        , Disburse.riRegistry = rv
                        , Disburse.riValidityHours =
                            dwOptsValidityHours
                        , Disburse.riTreasuryTxIns =
                            dwOptsTreasuryTxIns
                        }
            in  Right (answers, ri)

runContingencyDisburse
    :: GlobalOpts
    -> ContingencyDisburseOpts
    -> IO ()
runContingencyDisburse g ContingencyDisburseOpts{..} =
    runDisburseCommand
        "contingency-disburse-wizard"
        g
        cdOptsLog
        cdOptsMetadataPath
        cdOptsOut
        (Set.fromList [Contingency, cdOptsDestinationScope])
        Contingency
        $ \networkName rv verified -> do
            destinationAddr <-
                destinationScopeAddress
                    cdOptsDestinationScope
                    verified
            let answers =
                    Disburse.DisburseAnswers
                        { Disburse.daScope = Contingency
                        , Disburse.daUnit = ADA
                        , Disburse.daAmount = cdOptsAdaLovelace
                        , Disburse.daBeneficiaryAddrBech32 =
                            destinationAddr
                        , Disburse.daValidityHours =
                            cdOptsValidityHours
                        , Disburse.daRationale =
                            Disburse.RationaleAnswers
                                { Disburse.raDescription =
                                    cdOptsDescription
                                , Disburse.raJustification =
                                    cdOptsJustification
                                , Disburse.raDestinationLabel =
                                    destinationScopeLabel
                                        cdOptsDestinationScope
                                , Disburse.raEvent =
                                    Just "disburse"
                                , Disburse.raLabel =
                                    Just "Contingency disburse"
                                }
                        , Disburse.daExtraSigners = []
                        }
                ri =
                    Disburse.ResolverInput
                        { Disburse.riNetwork = networkName
                        , Disburse.riWalletAddrBech32 =
                            cdOptsWalletAddr
                        , Disburse.riBeneficiaryAddrBech32 =
                            destinationAddr
                        , Disburse.riScope = Contingency
                        , Disburse.riUnit = ADA
                        , Disburse.riAmount = cdOptsAdaLovelace
                        , Disburse.riRegistry = rv
                        , Disburse.riValidityHours =
                            cdOptsValidityHours
                        , Disburse.riTreasuryTxIns = []
                        }
            Right (answers, ri)

runDisburseCommand
    :: Text
    -> GlobalOpts
    -> Maybe FilePath
    -> FilePath
    -> Maybe FilePath
    -> Set.Set ScopeId
    -> ScopeId
    -> ( Text
         -> Disburse.RegistryView
         -> VerifiedRegistry
         -> Either Text (Disburse.DisburseAnswers, Disburse.ResolverInput)
       )
    -> IO ()
runDisburseCommand commandName g logPath metadataPath outPath verifyScopes sourceScope buildRun =
    withLogHandle logPath $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr =
                DisburseTrace.disburseEventTracerWithPrefix
                    commandName
                    textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortDisburse tr (T.pack e)
        let socket = fromMaybe "(unset)" (goSocketPath g)
            NetworkMagic magic = goNetworkMagic g
        traceWith
            tr
            ( DisburseTrace.DweNetwork
                networkName
                (fromIntegral magic)
            )
        traceWith tr (DisburseTrace.DweMetadata metadataPath)

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyDisburseRegistry
                        backend
                        metadataPath
                        verifyScopes
                        networkName
                (rv, registry) <- case verified of
                    Left e ->
                        abortDisburse
                            tr
                            ("verify: " <> T.pack (show e))
                    Right registry ->
                        case Disburse.registryViewFromVerified
                            sourceScope
                            registry of
                            Left e ->
                                abortDisburse
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure (view, registry)
                traceDisburseRegistryView tr sourceScope rv
                (answers, ri) <- case buildRun networkName rv registry of
                    Left e ->
                        abortDisburse tr ("prepare: " <> e)
                    Right run -> pure run
                let renv =
                        traceDisburseResolverEnv tr $
                            providerToDisburseResolverEnv backend
                er <- Disburse.resolveDisburseEnv renv ri
                env <- case er of
                    Left e ->
                        abortDisburse
                            tr
                            ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceDisburseEnv tr env
                intent <-
                    case Disburse.disburseToTreasuryIntent env answers of
                        Left de ->
                            abortDisburse
                                tr
                                ( "translate: "
                                    <> T.pack
                                        ( show
                                            ( de
                                                :: Disburse.DisburseError
                                            )
                                        )
                                )
                        Right i -> pure i
                traceWith tr $
                    DisburseTrace.DweUpperBoundResolved
                        (tiValidityUpperBoundSlot intent)
                traceWith tr (DisburseTrace.DweIntentReady outPath)
                let bytes =
                        encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SDisburse intent)
                case outPath of
                    Nothing -> BSL.putStr bytes
                    Just fp -> BSL.writeFile fp bytes

verifyDisburseRegistry
    :: Provider IO
    -> FilePath
    -> Set.Set ScopeId
    -> Text
    -> IO (Either RegistryWalkError VerifiedRegistry)
verifyDisburseRegistry backend metadataPath verifyScopes networkName = do
    verified <- verifyRegistry backend metadataPath verifyScopes
    case verified of
        Left err
            | T.toLower networkName == "devnet"
            , scopeOwnersAnchorSpent err ->
                devnetRegistryFromMetadata metadataPath verifyScopes
        _ -> pure verified

scopeOwnersAnchorSpent :: RegistryWalkError -> Bool
scopeOwnersAnchorSpent = \case
    AnchorSpent "scope_owners" Nothing _ -> True
    _ -> False

devnetRegistryFromMetadata
    :: FilePath
    -> Set.Set ScopeId
    -> IO (Either RegistryWalkError VerifiedRegistry)
devnetRegistryFromMetadata metadataPath verifyScopes = do
    decoded <- readUpstreamMetadataFile metadataPath
    pure $ decoded >>= devnetRegistryFromUpstream verifyScopes

devnetRegistryFromUpstream
    :: Set.Set ScopeId
    -> UpstreamMetadata
    -> Either RegistryWalkError VerifiedRegistry
devnetRegistryFromUpstream verifyScopes metadata = do
    scopesNftUtxo <-
        parseMetadataTxIn "scope_owners" (umScopeOwners metadata)
    scopesNftPolicy <-
        either
            (Left . ChainQueryError . T.pack)
            Right
            derivedScopesNftPolicy
    owner <-
        maybe
            (Left (ChainQueryError "devnet metadata contains no owner"))
            (mapParseError "owner" . keyHashFromHex)
            (listToMaybe (mapMaybe teOwner (Map.elems entries)))
    scopes <- traverse parseScope (Map.toList entries)
    pure
        VerifiedRegistry
            { vrScopesNftUtxo = scopesNftUtxo
            , vrScopesNftPolicy = scopesNftPolicy
            , vrOwners =
                Map.fromList
                    [ (CoreDevelopment, owner)
                    , (OpsAndUseCases, owner)
                    , (NetworkCompliance, owner)
                    , (Middleware, owner)
                    ]
            , vrTreasuriesByScope = Map.fromList scopes
            }
  where
    entries =
        Map.restrictKeys (umTreasuries metadata) verifyScopes
    parseScope (scope, entry) =
        (scope,) <$> devnetScopeFromMetadata scope entry

devnetScopeFromMetadata
    :: ScopeId
    -> TreasuryEntry
    -> Either RegistryWalkError VerifiedScope
devnetScopeFromMetadata scope entry = do
    address <- mapParseError "address" (addrFromText (teAddress entry))
    treasuryHash <-
        parseDeploymentHash "treasury_script.hash" (teTreasuryScript entry)
    registryHash <-
        parseDeploymentHash "registry_script.hash" (teRegistryScript entry)
    permissionsHash <-
        parseDeploymentHash
            "permissions_script.hash"
            (tePermissionsScript entry)
    registryTxIn <-
        parseDeploymentTxIn
            "registry_script.deployed_at"
            (teRegistryScript entry)
    treasuryTxIn <-
        parseDeploymentTxIn
            "treasury_script.deployed_at"
            (teTreasuryScript entry)
    permissionsTxIn <-
        parseDeploymentTxIn
            "permissions_script.deployed_at"
            (tePermissionsScript entry)
    pure
        VerifiedScope
            { vsAddress = address
            , vsTreasuryScriptHash = treasuryHash
            , vsRegistryScriptHash = registryHash
            , vsPermissionsScriptHash = permissionsHash
            , vsRegistryNftUtxo = registryTxIn
            , vsTreasuryDeployedAt = treasuryTxIn
            , vsPermissionsDeployedAt = permissionsTxIn
            , vsRegistryDeployedAt = registryTxIn
            }
  where
    scoped field = field <> " (" <> scopeText scope <> ")"
    parseDeploymentHash field deployment =
        mapParseError
            (scoped field)
            (scriptHashFromHex (sdHash deployment))
    parseDeploymentTxIn field deployment =
        parseMetadataTxIn (scoped field) (sdDeployedAt deployment)

parseMetadataTxIn
    :: Text -> TxInRef -> Either RegistryWalkError TxIn
parseMetadataTxIn field =
    mapParseError field . txInFromText . unTxInRef

mapParseError :: Text -> Either String a -> Either RegistryWalkError a
mapParseError field =
    either
        (Left . ChainQueryError . ((field <> ": ") <>) . T.pack)
        Right

destinationScopeAddress
    :: ScopeId -> VerifiedRegistry -> Either Text Text
destinationScopeAddress scope registry =
    case Disburse.registryViewFromVerified scope registry of
        Left e ->
            Left ("project destination: " <> T.pack (show e))
        Right rv ->
            case Map.lookup scope (Disburse.rvTreasuryByScope rv) of
                Nothing ->
                    Left
                        ( "verified destination scope missing: "
                            <> scopeText scope
                        )
                Just refs ->
                    Right (Disburse.trAddress refs)

destinationScopeLabel :: ScopeId -> Text
destinationScopeLabel scope =
    scopeDisplayName scope <> " treasury"

scopeDisplayName :: ScopeId -> Text
scopeDisplayName = \case
    CoreDevelopment -> "Core Development"
    OpsAndUseCases -> "Ops and Use Cases"
    NetworkCompliance -> "Network Compliance"
    Middleware -> "Middleware"
    Contingency -> "Contingency"

abortDisburse
    :: Tracer IO DisburseTrace.DisburseWizardEvent -> Text -> IO a
abortDisburse tr msg = do
    traceWith tr (DisburseTrace.DweAborted msg)
    exitWith (ExitFailure 3)

traceDisburseResolverEnv
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> Disburse.ResolverEnv IO
    -> Disburse.ResolverEnv IO
traceDisburseResolverEnv tr renv =
    Disburse.ResolverEnv
        { Disburse.reEnvQueryWalletUtxos = \addr -> do
            us <- Disburse.reEnvQueryWalletUtxos renv addr
            traceWith
                tr
                (DisburseTrace.DweWalletUtxosQueried (length us))
            pure us
        , Disburse.reEnvQueryTreasuryUtxos = \addr -> do
            us <- Disburse.reEnvQueryTreasuryUtxos renv addr
            traceWith
                tr
                ( DisburseTrace.DweTreasuryUtxosQueried
                    (length us)
                    (sum (lovelaceOfValue . snd <$> us))
                )
            pure us
        , Disburse.reEnvComputeUpperBound = \choice -> do
            result <- Disburse.reEnvComputeUpperBound renv choice
            case result of
                Right slot ->
                    traceWith tr (DisburseTrace.DweUpperBoundResolved slot)
                Left _ -> pure ()
            pure result
        }

traceDisburseRegistryView
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> ScopeId
    -> Disburse.RegistryView
    -> IO ()
traceDisburseRegistryView tr scope rv =
    case Map.lookup scope (Disburse.rvTreasuryByScope rv) of
        Just refs -> do
            traceWith tr $
                DisburseTrace.DweRegistryVerified
                    scope
                    (Disburse.trAddress refs)
                    (Disburse.trScriptHash refs)
                    (Disburse.rvRegistryPolicyId rv)
                    (Disburse.trPermissionsRewardAccount refs)
            let os = Disburse.rvOwners rv
            traceWith tr $
                DisburseTrace.DweOwners
                    (Disburse.soCore os)
                    (Disburse.soOps os)
                    (Disburse.soNetworkCompliance os)
                    (Disburse.soMiddleware os)
        Nothing ->
            abortDisburse
                tr
                "internal: missing scope in RegistryView (post-verify); please file a bug"

traceDisburseEnv
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> Disburse.DisburseEnv
    -> IO ()
traceDisburseEnv tr env = do
    let nc = Disburse.deNetworkConstants env
    traceWith tr $
        DisburseTrace.DweNetworkConstants
            (Disburse.ncUsdmPolicy nc)
            (Disburse.ncUsdmToken nc)
    let wsel = Disburse.deWalletSelection env
    traceWith tr $
        DisburseTrace.DweWalletUtxoSelected
            (Disburse.wsTxIn wsel)
    let tsel = Disburse.deTreasurySelection env
    traceWith tr $
        DisburseTrace.DweTreasuryUtxosSelected
            (Disburse.dtsInputs tsel)
            (Disburse.dtsLeftoverLovelace tsel)
            (Disburse.dtsLeftoverUsdm tsel)

providerToDisburseResolverEnv
    :: Provider IO -> Disburse.ResolverEnv IO
providerToDisburseResolverEnv p =
    Disburse.ResolverEnv
        { Disburse.reEnvQueryWalletUtxos = queryFlat p
        , Disburse.reEnvQueryTreasuryUtxos = queryValues p
        , Disburse.reEnvComputeUpperBound = \choice -> do
            r <- queryUpperBoundSlot p choice
            pure (fmap unwrapSlot r)
        }
  where
    unwrapSlot (SlotNo s) = s

lovelaceOfValue :: MaryValue -> Integer
lovelaceOfValue (MaryValue (Coin lovelace) _) = lovelace
