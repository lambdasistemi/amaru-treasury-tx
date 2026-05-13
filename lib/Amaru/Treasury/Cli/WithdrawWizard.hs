{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.WithdrawWizard
Description : CLI parser and runner for withdraw-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.WithdrawWizard
    ( WithdrawOpts (..)
    , withdrawOptsP
    , runWithdrawWizard
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
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (ExitCode (..), exitWith)

import Amaru.Treasury.Backend
    ( Provider
    , rewardAccountLovelace
    )
import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseRewardAccountForNetwork
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw
import Amaru.Treasury.Tx.WithdrawWizard.Trace qualified as WithdrawTrace

{- | Flags for the @withdraw-wizard@ subcommand.
Mirrors @specs/006-withdraw-wizard/contracts/withdraw-wizard-cli.md@.
-}
data WithdrawOpts = WithdrawOpts
    { wdOptsWalletAddr :: !Text
    , wdOptsMetadataPath :: !FilePath
    , wdOptsOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , wdOptsLog :: !(Maybe FilePath)
    -- ^ where to send 'WithdrawWizardEvent' lines. 'Nothing' = stderr.
    , wdOptsScope :: !ScopeId
    , wdOptsValidityHours :: !(Maybe Word16)
    , wdOptsDescription :: !(Maybe Text)
    , wdOptsJustification :: !(Maybe Text)
    , wdOptsDestinationLabel :: !(Maybe Text)
    , wdOptsEvent :: !(Maybe Text)
    , wdOptsLabel :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

withdrawOptsP :: Parser WithdrawOpts
withdrawOptsP =
    WithdrawOpts
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
                    <> help
                        "Rationale description override"
                )
            )
        <*> optional
            ( strOption
                ( long "justification"
                    <> metavar "TEXT"
                    <> help
                        "Rationale justification override"
                )
            )
        <*> optional
            ( strOption
                ( long "destination-label"
                    <> metavar "TEXT"
                    <> help
                        "Rationale destination label override"
                )
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event override (defaults withdraw)"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help
                        "Rationale label override (defaults Withdraw treasury rewards)"
                )
            )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

runWithdrawWizard :: GlobalOpts -> WithdrawOpts -> IO ()
runWithdrawWizard g WithdrawOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle wdOptsLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = WithdrawTrace.withdrawWizardEventTracer textTracer
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortWithdraw tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith
            tr
            ( WithdrawTrace.WweNetwork
                networkName
                (fromIntegral magic)
            )
        traceWith tr (WithdrawTrace.WweMetadata wdOptsMetadataPath)

        let answers =
                Withdraw.WithdrawAnswers
                    { Withdraw.waScope = wdOptsScope
                    , Withdraw.waValidityHours =
                        wdOptsValidityHours
                    , Withdraw.waDescription =
                        wdOptsDescription
                    , Withdraw.waJustification =
                        wdOptsJustification
                    , Withdraw.waDestinationLabel =
                        wdOptsDestinationLabel
                    , Withdraw.waEvent = wdOptsEvent
                    , Withdraw.waLabel = wdOptsLabel
                    }

        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        wdOptsMetadataPath
                        (Set.singleton wdOptsScope)
                rv <- case verified of
                    Left e ->
                        abortWithdraw
                            tr
                            ("verify: " <> T.pack (show e))
                    Right registry ->
                        case Withdraw.registryViewFromVerified
                            wdOptsScope
                            registry of
                            Left e ->
                                abortWithdraw
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                traceWithdrawRegistryView tr wdOptsScope rv
                let ri =
                        Withdraw.WithdrawResolverInput
                            { Withdraw.wriNetwork = networkName
                            , Withdraw.wriWalletAddrBech32 =
                                wdOptsWalletAddr
                            , Withdraw.wriScope = wdOptsScope
                            , Withdraw.wriRegistry = rv
                            , Withdraw.wriValidityHours =
                                wdOptsValidityHours
                            }
                    renv =
                        traceWithdrawResolverEnv tr $
                            providerToWithdrawResolverEnv
                                tr
                                networkName
                                backend
                er <- Withdraw.resolveWithdrawEnv renv ri
                env <- case er of
                    Left e ->
                        abortWithdraw
                            tr
                            ("resolve: " <> T.pack (show e))
                    Right e -> pure e
                traceWithdrawEnv tr env
                result <-
                    case Withdraw.withdrawToTreasuryResult env answers of
                        Left we ->
                            abortWithdraw
                                tr
                                ( "translate: "
                                    <> T.pack
                                        ( show
                                            ( we
                                                :: Withdraw.WithdrawError
                                            )
                                        )
                                )
                        Right r -> pure r
                case result of
                    Withdraw.WithdrawNoRewards account ->
                        traceWith tr (WithdrawTrace.WweNoRewards account)
                    Withdraw.WithdrawIntentReady intent -> do
                        traceWith tr $
                            WithdrawTrace.WweUpperBoundResolved
                                (tiValidityUpperBoundSlot intent)
                        traceWith tr (WithdrawTrace.WweIntentReady wdOptsOut)
                        let bytes =
                                encodeSomeTreasuryIntent
                                    (SomeTreasuryIntent SWithdraw intent)
                        case wdOptsOut of
                            Nothing -> BSL.putStr bytes
                            Just fp -> BSL.writeFile fp bytes

abortWithdraw
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent -> Text -> IO a
abortWithdraw tr msg = do
    traceWith tr (WithdrawTrace.WweAborted msg)
    exitWith (ExitFailure 3)

traceWithdrawResolverEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Withdraw.WithdrawResolverEnv IO
    -> Withdraw.WithdrawResolverEnv IO
traceWithdrawResolverEnv tr renv =
    Withdraw.WithdrawResolverEnv
        { Withdraw.wreQueryWalletUtxos = \addr -> do
            us <- Withdraw.wreQueryWalletUtxos renv addr
            traceWith
                tr
                (WithdrawTrace.WweWalletUtxosQueried (length us))
            pure us
        , Withdraw.wreQueryRewardsLovelace = \account -> do
            rewards <-
                Withdraw.wreQueryRewardsLovelace renv account
            traceWith
                tr
                (WithdrawTrace.WweRewardsQueried account rewards)
            pure rewards
        , Withdraw.wreComputeUpperBound = \choice -> do
            result <- Withdraw.wreComputeUpperBound renv choice
            case result of
                Right slot ->
                    traceWith tr (WithdrawTrace.WweUpperBoundResolved slot)
                Left _ -> pure ()
            pure result
        }

traceWithdrawRegistryView
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> ScopeId
    -> Withdraw.RegistryView
    -> IO ()
traceWithdrawRegistryView tr scope rv =
    case Map.lookup scope (Withdraw.rvTreasuryByScope rv) of
        Just refs ->
            traceWith tr $
                WithdrawTrace.WweRegistryVerified
                    scope
                    (Withdraw.trAddress refs)
                    (Withdraw.trScriptHash refs)
                    (Withdraw.rvRegistryPolicyId rv)
        Nothing ->
            abortWithdraw
                tr
                "internal: missing scope in RegistryView (post-verify); please file a bug"

traceWithdrawEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Withdraw.WithdrawEnv
    -> IO ()
traceWithdrawEnv tr env = do
    let wsel = Withdraw.weWalletSelection env
        rewardAccount = Withdraw.weTreasuryRewardAccount env
    traceWith tr $
        WithdrawTrace.WweWalletUtxoSelected
            (Withdraw.wsTxIn wsel)
    traceWith tr $
        WithdrawTrace.WweRewardAccountResolved rewardAccount
    traceWith tr $
        WithdrawTrace.WweRewardsQueried
            rewardAccount
            (Withdraw.weRewardsLovelace env)

providerToWithdrawResolverEnv
    :: Tracer IO WithdrawTrace.WithdrawWizardEvent
    -> Text
    -> Provider IO
    -> Withdraw.WithdrawResolverEnv IO
providerToWithdrawResolverEnv tr networkName p =
    Withdraw.WithdrawResolverEnv
        { Withdraw.wreQueryWalletUtxos = queryFlat p
        , Withdraw.wreQueryRewardsLovelace = \account -> do
            rewardAccount <- case parseRewardAccountForNetwork
                networkName
                account of
                Right value -> pure value
                Left e ->
                    abortWithdraw
                        tr
                        ( "resolve: reward account: "
                            <> T.pack e
                        )
            rewardAccountLovelace p rewardAccount
        , Withdraw.wreComputeUpperBound = \choice -> do
            r <- queryUpperBoundSlot p choice
            pure (fmap unwrapSlot r)
        }
  where
    unwrapSlot (SlotNo s) = s
