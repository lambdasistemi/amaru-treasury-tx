{- |
Module      : Amaru.Treasury.Tx.SwapWizard.Trace
Description : Tracer events for the swap-wizard pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Every step that affects the value of the produced
@intent.json@ is a constructor of 'WizardEvent'. The wizard
emits one event per step into a @'Tracer' IO 'WizardEvent'@.
The 'renderEvent' function turns each event into a single
human-readable line for log output.
-}
module Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , renderEvent
    , eventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Amaru.Treasury.Scope (ScopeId, scopeText)

-- | Steps the wizard takes that affect intent.json content.
data WizardEvent
    = -- | Network resolved from CLI flags.
      WeNetwork !Text !Word64
    | -- | About to read + verify a metadata file.
      WeMetadata !FilePath
    | -- | Verifier accepted the named scope; emits the
      --   chain-anchored hashes the wizard will commit to.
      WeRegistryVerified
        !ScopeId
        -- ^ requested scope
        !Text
        -- ^ treasuryAddress (bech32)
        !Text
        -- ^ treasuryScriptHash (hex)
        !Text
        -- ^ registryPolicyId (hex)
        !Text
        -- ^ permissionsRewardAccount (hex; = permissions hash)
    | -- | Owner key hashes parsed from the on-chain Scopes datum.
      WeOwners !Text !Text !Text !Text
    | -- | Curated NetworkConstants row used (build-time root).
      WeNetworkConstants
        !Text
        -- ^ swapOrderAddress
        !Text
        -- ^ usdmPolicy
        !Text
        -- ^ usdmToken
        !Integer
        -- ^ sundaeProtocolFeeLovelace
    | -- | Wallet UTxO query came back.
      WeWalletUtxosQueried !Int
    | -- | Wallet UTxO selected (largest pure-ADA).
      WeWalletUtxoSelected !Text
    | -- | Treasury UTxO query came back (count, total lovelace).
      WeTreasuryUtxosQueried !Int !Integer
    | -- | Treasury UTxOs picked + leftover lovelace.
      WeTreasuryUtxosSelected ![Text] !Integer
    | -- | All-ADA max-spend calculation facts.
      WeAllAdaPlan
        ![Text]
        -- ^ selected pure ADA treasury UTxOs
        !Integer
        -- ^ available lovelace
        !Integer
        -- ^ amount lovelace
        !Integer
        -- ^ implied USDM in smallest units
        !Integer
        -- ^ leftover lovelace
        !Integer
        -- ^ requested split count
        !Integer
        -- ^ produced chunk count
        !Integer
        -- ^ extra per chunk lovelace
        !Integer
        -- ^ total overhead lovelace
        !Integer
        -- ^ rate numerator
        !Integer
        -- ^ rate denominator
    | -- | Chain horizon helper resolved an upper-bound slot.
      WeUpperBoundResolved !Word64
    | -- | Chunks computed: total, chunkSize, fullChunks, remainder.
      WeChunksComputed !Integer !Integer !Int !Integer
    | -- | The wizard finished building intent.json and is about
      --   to write it (Nothing = stdout, Just = file path).
      WeIntentReady !(Maybe FilePath)
    | -- | The wizard refused before producing intent.json.
      WeAborted !Text
    deriving (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderEvent :: WizardEvent -> Text
renderEvent =
    ("swap-wizard: " <>) . body
  where
    body = \case
        WeNetwork name magic ->
            "network "
                <> name
                <> " (magic "
                <> tshow magic
                <> ")"
        WeMetadata path ->
            "metadata = " <> T.pack path
        WeRegistryVerified
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
        WeOwners core ops netc midl ->
            "owners core="
                <> core
                <> " ops="
                <> ops
                <> " network_compliance="
                <> netc
                <> " middleware="
                <> midl
        WeNetworkConstants swap usdmP usdmT fee ->
            "NetworkConstants swapOrder="
                <> swap
                <> " usdmPolicy="
                <> usdmP
                <> " usdmToken="
                <> usdmT
                <> " sundaeFee="
                <> tshow fee
        WeWalletUtxosQueried n ->
            "wallet utxos: " <> tshow n
        WeWalletUtxoSelected txin ->
            "wallet utxo selected " <> txin
        WeTreasuryUtxosQueried n total ->
            "treasury utxos: "
                <> tshow n
                <> " (total "
                <> tshow total
                <> " lovelace)"
        WeTreasuryUtxosSelected picks leftover ->
            "treasury utxos selected "
                <> T.intercalate "," picks
                <> " leftover="
                <> tshow leftover
        WeAllAdaPlan
            picks
            available
            amount
            impliedUsdm
            leftover
            split
            chunks
            extra
            overhead
            rateNum
            rateDen ->
                "all-ada selected="
                    <> T.intercalate "," picks
                    <> " available="
                    <> tshow available
                    <> " amount="
                    <> tshow amount
                    <> " impliedUsdm="
                    <> tshow impliedUsdm
                    <> " leftover="
                    <> tshow leftover
                    <> " split="
                    <> tshow split
                    <> " chunks="
                    <> tshow chunks
                    <> " extraPerChunk="
                    <> tshow extra
                    <> " overhead="
                    <> tshow overhead
                    <> " rate="
                    <> tshow rateNum
                    <> "/"
                    <> tshow rateDen
        WeUpperBoundResolved ub ->
            "upperBound slot "
                <> tshow ub
                <> " (from chain horizon helper)"
        WeChunksComputed total cs full rem' ->
            "chunks total="
                <> tshow total
                <> " chunkSize="
                <> tshow cs
                <> " full="
                <> tshow full
                <> " remainder="
                <> tshow rem'
        WeIntentReady Nothing ->
            "intent.json -> stdout"
        WeIntentReady (Just p) ->
            "intent.json -> " <> T.pack p
        WeAborted msg ->
            "ABORT " <> msg

-- | Lift a 'Text' sink into a 'WizardEvent' tracer via 'renderEvent'.
eventTracer :: Tracer m Text -> Tracer m WizardEvent
eventTracer = contramap renderEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
