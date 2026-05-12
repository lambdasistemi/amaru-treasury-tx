{- |
Module      : Amaru.Treasury.Tx.DisburseWizard.Trace
Description : Tracer events for the disburse-wizard pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapWizard.Trace`](Amaru.Treasury.Tx.SwapWizard.Trace.html)
for the disburse subcommand. Every step that affects the
value of the produced @intent.json@ is a constructor of
'DisburseWizardEvent'. The default sink is stderr;
@--log PATH@ in the CLI redirects to a file.
-}
module Amaru.Treasury.Tx.DisburseWizard.Trace
    ( DisburseWizardEvent (..)
    , renderDisburseWizardEvent
    , disburseWizardEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Amaru.Treasury.Scope (ScopeId, scopeText)

{- | Steps the disburse-wizard takes that affect intent.json
content.
-}
data DisburseWizardEvent
    = -- | Network resolved from CLI flags.
      DweNetwork !Text !Word64
    | -- | About to read + verify a metadata file.
      DweMetadata !FilePath
    | -- | Verifier accepted the named scope; emits the
      --   chain-anchored hashes the wizard will commit to.
      DweRegistryVerified
        !ScopeId
        -- ^ requested scope
        !Text
        -- ^ treasuryAddress (bech32)
        !Text
        -- ^ treasuryScriptHash (hex)
        !Text
        -- ^ registryPolicyId (hex)
        !Text
        -- ^ permissionsRewardAccount (hex; =
        --     permissions hash)
    | -- | Owner key hashes parsed from the on-chain
      --   Scopes datum.
      DweOwners !Text !Text !Text !Text
    | -- | NetworkConstants USDM rows used (the only
      --   constants this command actually reads).
      DweNetworkConstants
        !Text
        -- ^ usdmPolicy
        !Text
        -- ^ usdmToken
    | -- | Wallet UTxO query came back.
      DweWalletUtxosQueried !Int
    | -- | Wallet UTxO selected (largest pure-ADA).
      DweWalletUtxoSelected !Text
    | -- | Treasury UTxO query came back (count, total
      --   lovelace).
      DweTreasuryUtxosQueried !Int !Integer
    | -- | Treasury UTxOs picked + leftover lovelace +
      --   leftover USDM.
      DweTreasuryUtxosSelected
        ![Text]
        -- ^ chosen txid#ix list
        !Integer
        -- ^ leftover lovelace
        !Integer
        -- ^ leftover USDM (smallest unit)
    | -- | Chain horizon helper resolved an upper-bound slot.
      DweUpperBoundResolved !Word64
    | -- | The wizard finished building intent.json and
      --   is about to write it
      --   ('Nothing' = stdout, 'Just' = file path).
      DweIntentReady !(Maybe FilePath)
    | -- | The wizard refused before producing
      --   intent.json.
      DweAborted !Text
    deriving stock (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderDisburseWizardEvent :: DisburseWizardEvent -> Text
renderDisburseWizardEvent =
    ("disburse-wizard: " <>) . body
  where
    body = \case
        DweNetwork name magic ->
            "network "
                <> name
                <> " (magic "
                <> tshow magic
                <> ")"
        DweMetadata path ->
            "metadata = " <> T.pack path
        DweRegistryVerified
            scope
            addr
            treasuryHash
            registryPolicy
            permissionsHash ->
                "VERIFIED scope="
                    <> scopeText scope
                    <> " treasury="
                    <> addr
                    <> " treasuryScriptHash="
                    <> treasuryHash
                    <> " registryPolicyId="
                    <> registryPolicy
                    <> " permissionsRewardAccount="
                    <> permissionsHash
        DweOwners core ops netc midl ->
            "owners core="
                <> core
                <> " ops="
                <> ops
                <> " network_compliance="
                <> netc
                <> " middleware="
                <> midl
        DweNetworkConstants usdmP usdmT ->
            "NetworkConstants usdmPolicy="
                <> usdmP
                <> " usdmToken="
                <> usdmT
        DweWalletUtxosQueried n ->
            "wallet utxos: " <> tshow n
        DweWalletUtxoSelected txin ->
            "wallet utxo selected " <> txin
        DweTreasuryUtxosQueried n total ->
            "treasury utxos: "
                <> tshow n
                <> " (total "
                <> tshow total
                <> " lovelace)"
        DweTreasuryUtxosSelected picks lov usdm ->
            "treasury utxos selected "
                <> T.intercalate "," picks
                <> " leftoverLov="
                <> tshow lov
                <> " leftoverUsdm="
                <> tshow usdm
        DweUpperBoundResolved ub ->
            "upperBound slot "
                <> tshow ub
                <> " (from chain horizon helper)"
        DweIntentReady Nothing ->
            "intent.json -> stdout"
        DweIntentReady (Just p) ->
            "intent.json -> " <> T.pack p
        DweAborted msg ->
            "ABORT " <> msg

{- | Lift a 'Text' sink into a 'DisburseWizardEvent'
tracer via 'renderDisburseWizardEvent'.
-}
disburseWizardEventTracer
    :: Tracer m Text -> Tracer m DisburseWizardEvent
disburseWizardEventTracer =
    contramap renderDisburseWizardEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
