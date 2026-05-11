{-# LANGUAGE RecordWildCards #-}

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
    , disburseWizardOptsP
    , runDisburseWizard
    ) where

import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word8)
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

import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , nowTip
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
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
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
    , dwOptsValidityHours :: !Word8
    , dwOptsDescription :: !Text
    , dwOptsJustification :: !Text
    , dwOptsDestinationLabel :: !Text
    , dwOptsEvent :: !(Maybe Text)
    , dwOptsLabel :: !(Maybe Text)
    , dwOptsSigners :: ![Text]
    -- ^ accumulated extra-signer flags; empty = selected
    --   scope owner only.
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
            scopeReader
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

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

unitReader :: ReadM Unit
unitReader =
    eitherReader $ \s -> case map toLower s of
        "ada" -> Right ADA
        "usdm" -> Right USDM
        _ -> Left "expected ada or usdm"

runDisburseWizard
    :: GlobalOpts
    -> DisburseWizardOpts
    -> IO ()
runDisburseWizard g DisburseWizardOpts{..} =
    withLogHandle dwOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = DisburseTrace.disburseWizardEventTracer textTracer
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
        traceWith tr (DisburseTrace.DweMetadata dwOptsMetadataPath)

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

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        dwOptsMetadataPath
                        (Set.singleton dwOptsScope)
                rv <- case verified of
                    Left e ->
                        abortDisburse
                            tr
                            ("verify: " <> T.pack (show e))
                    Right registry ->
                        case Disburse.registryViewFromVerified
                            dwOptsScope
                            registry of
                            Left e ->
                                abortDisburse
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                traceDisburseRegistryView tr dwOptsScope rv
                let ri =
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
                            }
                    renv =
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
                    DisburseTrace.DweValidityComputed
                        (Disburse.deCurrentTip env)
                        (tiValidityUpperBoundSlot intent)
                traceWith tr (DisburseTrace.DweIntentReady dwOptsOut)
                let bytes =
                        encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SDisburse intent)
                case dwOptsOut of
                    Nothing -> BSL.putStr bytes
                    Just fp -> BSL.writeFile fp bytes

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
        , Disburse.reEnvCurrentTip = do
            t <- Disburse.reEnvCurrentTip renv
            traceWith tr (DisburseTrace.DweTipRead t)
            pure t
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
        , Disburse.reEnvCurrentTip = nowTip p
        }

lovelaceOfValue :: MaryValue -> Integer
lovelaceOfValue (MaryValue (Coin lovelace) _) = lovelace
