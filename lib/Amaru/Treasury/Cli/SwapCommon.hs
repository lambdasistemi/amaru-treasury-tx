{-# LANGUAGE LambdaCase #-}

{- |
Module      : Amaru.Treasury.Cli.SwapCommon
Description : Shared swap CLI runtime helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.SwapCommon
    ( currentIso8601
    , resolveSwapQuoteObservation
    , abortTr
    , traceResolverEnv
    , traceRegistryView
    , traceEnv
    , providerToResolverEnv
    ) where

import Control.Tracer (Tracer, traceWith)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Exit (ExitCode (..), exitWith)

import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Cli.Common
    ( queryFlat
    )
import Amaru.Treasury.Cli.SwapOptions
    ( SwapQuoteQuoteArg (..)
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.SwapQuote
    ( QuoteObservation
    )
import Amaru.Treasury.Tx.SwapQuote.Source
    ( coingeckoAdaUsdmProvider
    , fetchQuoteSource
    , renderQuoteSourceError
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants (..)
    , RegistryView (..)
    , ResolverEnv (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , TreasurySelection (..)
    , WalletSelection (..)
    , WizardEnv (..)
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    )

currentIso8601 :: IO Text
currentIso8601 =
    T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
        <$> getCurrentTime

resolveSwapQuoteObservation
    :: Tracer IO WizardEvent
    -> Text
    -> SwapQuoteQuoteArg
    -> IO QuoteObservation
resolveSwapQuoteObservation tr observedAt = \case
    SwapQuoteOverride observation ->
        pure observation
    SwapQuoteSource source -> do
        result <- fetchQuoteSource coingeckoAdaUsdmProvider source observedAt
        case result of
            Right observation ->
                pure observation
            Left err ->
                abortTr tr (renderQuoteSourceError err)

abortTr :: Tracer IO WizardEvent -> Text -> IO a
abortTr tr msg = do
    traceWith tr (WeAborted msg)
    exitWith (ExitFailure 3)

traceResolverEnv
    :: Tracer IO WizardEvent
    -> ResolverEnv IO
    -> ResolverEnv IO
traceResolverEnv tr renv =
    ResolverEnv
        { reEnvQueryWalletUtxos = \addr -> do
            us <- reEnvQueryWalletUtxos renv addr
            traceWith tr (WeWalletUtxosQueried (length us))
            pure us
        , reEnvQueryTreasuryUtxos = \addr -> do
            us <- reEnvQueryTreasuryUtxos renv addr
            traceWith
                tr
                ( WeTreasuryUtxosQueried
                    (length us)
                    (sum (map (\(_, l, _) -> l) us))
                )
            pure us
        , reEnvComputeUpperBound = \choice -> do
            result <- reEnvComputeUpperBound renv choice
            case result of
                Right slot -> traceWith tr (WeUpperBoundResolved slot)
                Left _ -> pure ()
            pure result
        }

traceRegistryView
    :: Tracer IO WizardEvent
    -> ScopeId
    -> RegistryView
    -> IO ()
traceRegistryView tr scope rv = do
    let refs = svRefs (mkScopeView scope rv)
    traceWith tr $
        WeRegistryVerified
            scope
            (trAddress refs)
            (trScriptHash refs)
            (rvRegistryPolicyId rv)
            (trPermissionsRewardAccount refs)
    let os = rvOwners rv
    traceWith tr $
        WeOwners
            (soCore os)
            (soOps os)
            (soNetworkCompliance os)
            (soMiddleware os)

mkScopeView :: ScopeId -> RegistryView -> ScopeView
mkScopeView scope rv =
    case Map.lookup scope (rvTreasuryByScope rv) of
        Just refs ->
            ScopeView
                { svScope = scope
                , svRefs = refs
                , svDefaultSigners = []
                }
        Nothing ->
            error "swap CLI: missing scope in RegistryView (post-verify)"

traceEnv :: Tracer IO WizardEvent -> WizardEnv -> IO ()
traceEnv tr env = do
    let nc = weNetworkConstants env
    traceWith tr $
        WeNetworkConstants
            (ncSwapOrderAddress nc)
            (ncUsdmPolicy nc)
            (ncUsdmToken nc)
            (ncSundaeProtocolFeeLovelace nc)
    let wsel = weWalletSelection env
    traceWith tr $
        WeWalletUtxoSelected (wsTxIn wsel)
    let tsel = weTreasurySelection env
    traceWith tr $
        WeTreasuryUtxosSelected
            (tsInputs tsel)
            (tsLeftoverLovelace tsel)

providerToResolverEnv :: Provider IO -> ResolverEnv IO
providerToResolverEnv p =
    ResolverEnv
        { reEnvQueryWalletUtxos = queryFlat p
        , reEnvQueryTreasuryUtxos = queryFlat p
        , reEnvComputeUpperBound = \choice -> do
            r <- queryUpperBoundSlot p choice
            pure (fmap unwrapSlot r)
        }
  where
    unwrapSlot (SlotNo s) = s
