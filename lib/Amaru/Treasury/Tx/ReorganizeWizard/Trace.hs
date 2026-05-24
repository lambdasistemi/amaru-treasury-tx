{- |
Module      : Amaru.Treasury.Tx.ReorganizeWizard.Trace
Description : Tracer events for the reorganize-wizard pipeline
              (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapWizard.Trace`](Amaru.Treasury.Tx.SwapWizard.Trace.html)
and
[`Amaru.Treasury.Tx.DisburseWizard.Trace`](Amaru.Treasury.Tx.DisburseWizard.Trace.html)
for the reorganize subcommand.

Every step that the pure-Either entry point
'Amaru.Treasury.Wizard.Reorganize.buildReorganizeIntent'
takes between opening the backend and emitting the typed
intent surfaces as a constructor of
'ReorganizeWizardEvent'.  Events are informational only —
running with @nullTracer@ produces the same intent as a
recording tracer.

Constructor coverage is intentionally narrower than the
disburse equivalent: the existing CLI runner
('Amaru.Treasury.Cli.ReorganizeWizard.runReorganizeWizard')
wrote directly to stderr and emitted no tracer events, so
there is no prior byte-identity contract to preserve.  The
constructors here are the minimum needed for an
operator-facing log to step through the
intent-construction sequence.
-}
module Amaru.Treasury.Tx.ReorganizeWizard.Trace
    ( ReorganizeWizardEvent (..)
    , renderReorganizeWizardEvent
    , reorganizeWizardEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Amaru.Treasury.Scope (ScopeId, scopeText)

{- | Steps the reorganize-wizard takes that affect the
emitted typed intent.
-}
data ReorganizeWizardEvent
    = -- | Network resolved from CLI flags.
      RweNetwork !Text !Word64
    | -- | About to read + decode a metadata file.
      RweMetadata !FilePath
    | -- | Scope located + owner present in the metadata.
      RweScopeResolved !ScopeId
    | -- | Wallet UTxO picked (largest pure-ADA, post
      --   exclude / extra-tx-in filtering).
      RweWalletUtxoSelected !Text
    | -- | Count of treasury UTxOs the resolver enumerated
      --   at the treasury address.
      RweTreasuryUtxosResolved !Int
    | -- | Chain horizon helper resolved an upper-bound slot.
      RweUpperBoundResolved !Word64
    | -- | The wizard finished building the intent and is
      --   about to write / return it ('Nothing' = caller
      --   consumes in-memory, 'Just' = file path the CLI
      --   shell will write to).
      RweIntentReady !(Maybe FilePath)
    | -- | The wizard refused before producing the intent.
      RweAborted !Text
    deriving stock (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderReorganizeWizardEvent
    :: ReorganizeWizardEvent -> Text
renderReorganizeWizardEvent =
    ("reorganize-wizard: " <>) . body
  where
    body = \case
        RweNetwork name magic ->
            "network "
                <> name
                <> " (magic "
                <> tshow magic
                <> ")"
        RweMetadata path ->
            "metadata = " <> T.pack path
        RweScopeResolved scope ->
            "scope resolved: " <> scopeText scope
        RweWalletUtxoSelected txin ->
            "wallet utxo selected " <> txin
        RweTreasuryUtxosResolved n ->
            "treasury utxos resolved: " <> tshow n
        RweUpperBoundResolved ub ->
            "upperBound slot "
                <> tshow ub
                <> " (from chain horizon helper)"
        RweIntentReady Nothing ->
            "intent.json -> stdout"
        RweIntentReady (Just p) ->
            "intent.json -> " <> T.pack p
        RweAborted msg ->
            "ABORT " <> msg

{- | Lift a 'Text' sink into a 'ReorganizeWizardEvent'
tracer via 'renderReorganizeWizardEvent'.
-}
reorganizeWizardEventTracer
    :: Tracer m Text -> Tracer m ReorganizeWizardEvent
reorganizeWizardEventTracer =
    contramap renderReorganizeWizardEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
