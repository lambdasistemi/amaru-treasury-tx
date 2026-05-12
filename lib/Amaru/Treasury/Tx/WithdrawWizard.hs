{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Tx.WithdrawWizard
Description : Typed-Q&A wizard for the withdraw subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Typed operator answers plus a resolved chain environment
for the withdraw action. The pure translation emits the
unified 'TreasuryIntent' @'Withdraw@ shape consumed by
@tx-build@.
-}
module Amaru.Treasury.Tx.WithdrawWizard
    ( -- * Answers
      WithdrawAnswers (..)

      -- * Resolved environment
    , WithdrawEnv (..)
    , WithdrawNetworkConstants (..)
    , RegistryView (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)

      -- * Resolution
    , WithdrawResolverInput (..)
    , WithdrawResolverEnv (..)
    , WithdrawResolverError (..)
    , registryViewFromVerified
    , resolveWithdrawEnv

      -- * Pure translation
    , WithdrawError (..)
    , WithdrawResult (..)
    , withdrawToTreasuryIntent
    , withdrawToTreasuryResult
    ) where

import Cardano.Ledger.BaseTypes (Network (..))
import Control.Monad (when)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word64)

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , WithdrawInputs (..)
    )
import Amaru.Treasury.Scope (ScopeId, scopeText)
import Amaru.Treasury.Tx.SwapWizard
    ( RegistryView (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , addrNetwork
    , registryViewFromVerified
    , selectWallet
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the withdraw wizard.
The reward account and reward amount are deliberately
absent: they come from the resolver, not from CLI input.
-}
data WithdrawAnswers = WithdrawAnswers
    { waScope :: !ScopeId
    , waValidityHours :: !(Maybe Word16)
    -- ^ Optional signing window. 'Nothing' = use the chain
    --   horizon ('Validity.AutoLongest'); 'Just 0' is rejected;
    --   'Just n' (n > 0) is fed in as 'Validity.ExactlyHours'.
    , waDescription :: !(Maybe Text)
    , waJustification :: !(Maybe Text)
    , waDestinationLabel :: !(Maybe Text)
    , waEvent :: !(Maybe Text)
    , waLabel :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance FromJSON WithdrawAnswers where
    parseJSON = withObject "WithdrawAnswers" $ \o ->
        WithdrawAnswers
            <$> o .: "scope"
            <*> o .:? "validityHours"
            <*> o .:? "description"
            <*> o .:? "justification"
            <*> o .:? "destinationLabel"
            <*> o .:? "event"
            <*> o .:? "label"

{- | Withdraw only needs slot conversion from the network
constants table. Keep the type separate from swap's
Sundae/USDM constants so withdraw fixtures cannot carry
irrelevant placeholder state.
-}
newtype WithdrawNetworkConstants = WithdrawNetworkConstants
    { wncSlotsPerHour :: Word64
    }
    deriving stock (Eq, Show)

instance FromJSON WithdrawNetworkConstants where
    parseJSON = withObject "WithdrawNetworkConstants" $ \o ->
        WithdrawNetworkConstants
            <$> o .: "slotsPerHour"

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Everything the resolver hands the pure translation.
Pure 'withdrawToTreasuryIntent' reads only this record
plus 'WithdrawAnswers'; it never performs IO.
-}
data WithdrawEnv = WithdrawEnv
    { weNetwork :: !Text
    -- ^ @"mainnet"@ / @"preprod"@ / @"preview"@
    , weUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied @invalid-hereafter@ slot. Already
    --   horizon-validated; the pure translator just stamps it.
    , weNetworkConstants :: !WithdrawNetworkConstants
    -- ^ slot conversion constants
    , weRegistry :: !RegistryView
    , weScopeView :: !ScopeView
    , weWalletSelection :: !WalletSelection
    , weTreasuryRewardAccount :: !Text
    -- ^ 28-byte hex stake-script hash for the selected treasury
    , weRewardsLovelace :: !Integer
    -- ^ rewards balance resolved from chain state
    }
    deriving stock (Eq, Show)

instance FromJSON WithdrawEnv where
    parseJSON = withObject "WithdrawEnv" $ \o ->
        WithdrawEnv
            <$> o .: "network"
            <*> o .: "upperBoundSlot"
            <*> o .: "networkConstants"
            <*> o .: "registry"
            <*> o .: "scopeView"
            <*> o .: "walletSelection"
            <*> o .: "treasuryRewardAccount"
            <*> o .: "rewardsLovelace"

-- ----------------------------------------------------
-- Pure translation
-- ----------------------------------------------------

data WithdrawError
    = WithdrawRewardsNotPositive
    | -- | @--validity-hours = Just 0@.
      WithdrawValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots the chain
      --   horizon. Payload from 'Validity.HorizonError'.
      WithdrawValidityOvershoot !Validity.HorizonError
    | WithdrawScopeMismatch !ScopeId !ScopeId
    | WithdrawNetworkUnsupported !Text
    | WithdrawNetworkMismatch !Text !Text
    deriving stock (Eq, Show)

data WithdrawResult
    = WithdrawIntentReady !(TreasuryIntent 'Withdraw)
    | WithdrawNoRewards !Text
    deriving stock (Eq, Show)

{- | Pure translation to the unified schema-v1
'TreasuryIntent' withdraw shape.
-}
withdrawToTreasuryIntent
    :: WithdrawEnv
    -> WithdrawAnswers
    -> Either WithdrawError (TreasuryIntent 'Withdraw)
withdrawToTreasuryIntent env ans =
    case withdrawToTreasuryResult env ans of
        Right (WithdrawIntentReady intent) -> Right intent
        Right (WithdrawNoRewards _account) ->
            Left WithdrawRewardsNotPositive
        Left err -> Left err

{- | Pure translation result including the zero-rewards no-op case.
The existing 'withdrawToTreasuryIntent' wrapper remains fail-closed
for callers that only know how to consume an intent.
-}
withdrawToTreasuryResult
    :: WithdrawEnv -> WithdrawAnswers -> Either WithdrawError WithdrawResult
withdrawToTreasuryResult env ans = do
    validateAnswersAndScope env ans
    case compare (weRewardsLovelace env) 0 of
        LT -> Left WithdrawRewardsNotPositive
        EQ ->
            Right $
                WithdrawNoRewards
                    (weTreasuryRewardAccount env)
        GT ->
            Right $
                WithdrawIntentReady $
                    mkIntent env ans

mkIntent :: WithdrawEnv -> WithdrawAnswers -> TreasuryIntent 'Withdraw
mkIntent env ans =
    TreasuryIntent
        { tiSAction = SWithdraw
        , tiSchema = 1
        , tiNetwork = weNetwork env
        , tiWallet = mkWallet (weWalletSelection env)
        , tiScope = mkScope env ans
        , tiSigners = []
        , tiValidityUpperBoundSlot = weUpperBoundSlot env
        , tiRationale = mkRationale ans
        , tiPayload =
            WithdrawInputs
                { wdiTreasuryRewardAccount =
                    weTreasuryRewardAccount env
                , wdiRewardsLovelace = weRewardsLovelace env
                }
        }

validateAnswersAndScope
    :: WithdrawEnv -> WithdrawAnswers -> Either WithdrawError ()
validateAnswersAndScope env ans = do
    case waValidityHours ans of
        Just 0 -> Left WithdrawValidityHoursZero
        _ -> pure ()
    let resolvedScope = svScope (weScopeView env)
    when
        (waScope ans /= resolvedScope)
        (Left (WithdrawScopeMismatch (waScope ans) resolvedScope))
    case networkFamily (weNetwork env) of
        Nothing ->
            Left (WithdrawNetworkUnsupported (weNetwork env))
        Just expected ->
            case addrNetwork (trAddress (svRefs (weScopeView env))) of
                Just observed
                    | observed /= expected ->
                        Left
                            ( WithdrawNetworkMismatch
                                (weNetwork env)
                                (networkText observed)
                            )
                _ -> Right ()

mkWallet :: WalletSelection -> WalletJSON
mkWallet ws =
    WalletJSON
        { wjTxIn = wsTxIn ws
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

mkScope :: WithdrawEnv -> WithdrawAnswers -> ScopeJSON
mkScope env ans =
    let r = weRegistry env
        s = svRefs (weScopeView env)
    in  ScopeJSON
            { sjId = scopeText (waScope ans)
            , sjTreasuryAddress = trAddress s
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = Map.empty
            , sjTreasuryScriptHash = trScriptHash s
            , sjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , sjScopesDeployedAt = rvScopesDeployedAt r
            , sjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , sjTreasuryDeployedAt = rvTreasuryDeployedAt r
            , sjRegistryDeployedAt = rvRegistryDeployedAt r
            , sjRegistryPolicyId = rvRegistryPolicyId r
            }

mkRationale :: WithdrawAnswers -> RationaleJSON
mkRationale ans =
    let scopeName = scopeText (waScope ans)
    in  RationaleJSON
            { rjEvent = fromMaybe "withdraw" (waEvent ans)
            , rjLabel =
                fromMaybe
                    "Withdraw treasury rewards"
                    (waLabel ans)
            , rjDescription =
                fromMaybe
                    ("Withdraw accumulated rewards for " <> scopeName)
                    (waDescription ans)
            , rjJustification =
                fromMaybe
                    "Move rewards back under treasury contract control"
                    (waJustification ans)
            , rjDestinationLabel =
                fromMaybe
                    (scopeName <> " treasury")
                    (waDestinationLabel ans)
            }

networkFamily :: Text -> Maybe Network
networkFamily n = case T.toLower n of
    "mainnet" -> Just Mainnet
    "preprod" -> Just Testnet
    "preview" -> Just Testnet
    _ -> Nothing

networkText :: Network -> Text
networkText = \case
    Mainnet -> "mainnet"
    Testnet -> "testnet"

-- ----------------------------------------------------
-- Resolution
-- ----------------------------------------------------

{- | Inputs the resolver needs from the CLI. The reward
account and reward amount are intentionally absent: the
resolver derives them from verified registry/provider
state.
-}
data WithdrawResolverInput = WithdrawResolverInput
    { wriNetwork :: !Text
    , wriWalletAddrBech32 :: !Text
    , wriScope :: !ScopeId
    , wriRegistry :: !RegistryView
    , wriValidityHours :: !(Maybe Word16)
    -- ^ Operator-supplied @--validity-hours@; 'Nothing' = use
    --   chain horizon.
    }
    deriving stock (Eq, Show)

{- | Effects the withdraw resolver pulls from the backend.
The record keeps tests deterministic without depending on a
live node.
-}
data WithdrawResolverEnv m = WithdrawResolverEnv
    { wreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ for the wallet.
    , wreQueryRewardsLovelace :: !(Text -> m Integer)
    -- ^ Rewards for a 28-byte treasury reward account hash.
    , wreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    -- ^ Horizon helper.
    }

data WithdrawResolverError
    = WithdrawResolverNetworkUnsupported !Text
    | WithdrawResolverNetworkMismatch !Text !Text
    | WithdrawResolverScopeUnsupported !ScopeId
    | WithdrawResolverEmptyWalletUtxos
    | -- | @--validity-hours = Just 0@.
      WithdrawResolverValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots horizon.
      WithdrawResolverValidityOvershoot !Validity.HorizonError
    deriving stock (Eq, Show)

{- | Drive the resolver's @wreComputeUpperBound@ effect with
the operator's optional @--validity-hours@. Same logic as the
swap/disburse wizards' 'resolveUpperBound'.
-}
resolveUpperBound
    :: (Monad m)
    => (Validity.ValidityChoice -> m (Either Validity.HorizonError Word64))
    -> Maybe Word16
    -> m (Either WithdrawResolverError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 -> pure (Left WithdrawResolverValidityHoursZero)
    other -> do
        let choice =
                maybe Validity.AutoLongest Validity.ExactlyHours other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left (WithdrawResolverValidityOvershoot horizonErr)
            Right slot -> Right slot

{- | Resolve chain-derived withdraw inputs. The selected
treasury reward account is the selected scope's treasury
script hash, and the reward amount comes from the provider
hook for that account.
-}
resolveWithdrawEnv
    :: (Monad m)
    => WithdrawResolverEnv m
    -> WithdrawResolverInput
    -> m (Either WithdrawResolverError WithdrawEnv)
resolveWithdrawEnv renv input =
    case ( networkFamily (wriNetwork input)
         , addrNetwork (wriWalletAddrBech32 input)
         ) of
        (Nothing, _) ->
            pure
                ( Left
                    ( WithdrawResolverNetworkUnsupported
                        (wriNetwork input)
                    )
                )
        (Just want, Just observed)
            | observed /= want ->
                pure
                    ( Left
                        ( WithdrawResolverNetworkMismatch
                            (wriNetwork input)
                            (networkText observed)
                        )
                    )
        _ ->
            resolveWithScope renv input

resolveWithScope
    :: (Monad m)
    => WithdrawResolverEnv m
    -> WithdrawResolverInput
    -> m (Either WithdrawResolverError WithdrawEnv)
resolveWithScope renv input =
    case Map.lookup
        (wriScope input)
        (rvTreasuryByScope (wriRegistry input)) of
        Nothing ->
            pure
                ( Left
                    ( WithdrawResolverScopeUnsupported
                        (wriScope input)
                    )
                )
        Just refs -> do
            walletUtxos <-
                wreQueryWalletUtxos renv (wriWalletAddrBech32 input)
            case selectWallet 1 walletUtxos of
                Left _ ->
                    pure (Left WithdrawResolverEmptyWalletUtxos)
                Right ([], _) ->
                    pure (Left WithdrawResolverEmptyWalletUtxos)
                Right (walletRef : _, _) -> do
                    let rewardAccount = trScriptHash refs
                    rewards <-
                        wreQueryRewardsLovelace renv rewardAccount
                    upper <-
                        resolveUpperBound
                            (wreComputeUpperBound renv)
                            (wriValidityHours input)
                    case upper of
                        Left e -> pure (Left e)
                        Right upperBound ->
                            pure $
                                Right
                                    WithdrawEnv
                                        { weNetwork = wriNetwork input
                                        , weUpperBoundSlot = upperBound
                                        , weNetworkConstants =
                                            withdrawNetworkConstants
                                        , weRegistry = wriRegistry input
                                        , weScopeView =
                                            ScopeView
                                                { svScope = wriScope input
                                                , svRefs = refs
                                                , svDefaultSigners = []
                                                }
                                        , weWalletSelection =
                                            WalletSelection
                                                { wsTxIn = walletRef
                                                , wsAddress =
                                                    wriWalletAddrBech32 input
                                                , wsExtraTxIns = []
                                                }
                                        , weTreasuryRewardAccount =
                                            rewardAccount
                                        , weRewardsLovelace = rewards
                                        }

withdrawNetworkConstants :: WithdrawNetworkConstants
withdrawNetworkConstants =
    WithdrawNetworkConstants
        { wncSlotsPerHour = 3600
        }
