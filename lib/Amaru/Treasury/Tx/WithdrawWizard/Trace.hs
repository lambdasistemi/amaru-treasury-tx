{- |
Module      : Amaru.Treasury.Tx.WithdrawWizard.Trace
Description : Tracer events for the withdraw-wizard pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapWizard.Trace`](Amaru.Treasury.Tx.SwapWizard.Trace.html)
for the withdraw subcommand. Every step that affects the
value of the produced @intent.json@ is a constructor of
'WithdrawWizardEvent'.
-}
module Amaru.Treasury.Tx.WithdrawWizard.Trace
    ( WithdrawWizardEvent (..)
    , renderWithdrawWizardEvent
    , withdrawWizardEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Amaru.Treasury.Scope (ScopeId, scopeText)

data WithdrawWizardEvent
    = WweNetwork !Text !Word64
    | WweMetadata !FilePath
    | WweRegistryVerified
        !ScopeId
        -- ^ requested scope
        !Text
        -- ^ treasuryAddress
        !Text
        -- ^ treasuryScriptHash
        !Text
        -- ^ registryPolicyId
    | WweWalletUtxosQueried !Int
    | WweWalletUtxoSelected !Text
    | WweRewardAccountResolved !Text
    | WweRewardsQueried !Text !Integer
    | WweNoRewards !Text
    | WweTipRead !Word64
    | WweValidityComputed !Word64 !Word64
    | WweIntentReady !(Maybe FilePath)
    | WweAborted !Text
    deriving stock (Eq, Show)

renderWithdrawWizardEvent :: WithdrawWizardEvent -> Text
renderWithdrawWizardEvent =
    ("withdraw-wizard: " <>) . body
  where
    body = \case
        WweNetwork name magic ->
            "network "
                <> name
                <> " (magic "
                <> tshow magic
                <> ")"
        WweMetadata path ->
            "metadata = " <> T.pack path
        WweRegistryVerified scope addr treasuryHash registryPolicy ->
            "VERIFIED scope="
                <> scopeText scope
                <> " treasury="
                <> addr
                <> " treasuryScriptHash="
                <> treasuryHash
                <> " registryPolicyId="
                <> registryPolicy
        WweWalletUtxosQueried n ->
            "wallet utxos: " <> tshow n
        WweWalletUtxoSelected txin ->
            "wallet utxo selected " <> txin
        WweRewardAccountResolved account ->
            "reward account " <> account
        WweRewardsQueried account lovelace ->
            "rewards account="
                <> account
                <> " lovelace="
                <> tshow lovelace
        WweNoRewards account ->
            "zero rewards: nothing to withdraw account="
                <> account
                <> " lovelace=0"
        WweTipRead slot ->
            "tip slot " <> tshow slot
        WweValidityComputed tip ub ->
            "validity tip="
                <> tshow tip
                <> " upperBound="
                <> tshow ub
                <> " (+"
                <> tshow (ub - tip)
                <> " slots)"
        WweIntentReady Nothing ->
            "intent.json -> stdout"
        WweIntentReady (Just p) ->
            "intent.json -> " <> T.pack p
        WweAborted msg ->
            "ABORT " <> msg

withdrawWizardEventTracer
    :: Tracer m Text -> Tracer m WithdrawWizardEvent
withdrawWizardEventTracer =
    contramap renderWithdrawWizardEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
