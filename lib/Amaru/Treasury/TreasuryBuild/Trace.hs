{- |
Module      : Amaru.Treasury.TreasuryBuild.Trace
Description : Tracer events for the unified tx-build pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`Amaru.Treasury.Tx.Swap.Trace.SwapEvent`](Amaru.Treasury.Tx.Swap.Trace.html)
shape but adds three events specific to the unified
intent: 'TbeIntentParsed' (the action + network read
from the intent), 'TbeNetworkOk' / 'TbeNetworkMismatch'
(the N2C handshake magic vs @intent.network@), and
'TbeWroteSummary' (the summary sidecar path).

Constructor prefix @Tbe-@ for "TreasuryBuildEvent" so
traces are distinguishable when both unified and per-
action tracers are visible (mostly during the migration
transition; per-action tracers retire in T028).
-}
module Amaru.Treasury.TreasuryBuild.Trace
    ( BuildEvent (..)
    , renderBuildEvent
    , buildEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)

{- | Steps the unified @tx-build@ subcommand takes that
affect the produced tx CBOR or the summary sidecar.
-}
data BuildEvent
    = -- | Where the intent.json came from
      --   ('Nothing' = stdin, 'Just' = file path).
      TbeIntentSource !(Maybe FilePath)
    | -- | Action + network read from the parsed intent.
      --   Surfaces the action the build is about to
      --   construct, sourced from the intent.
      TbeIntentParsed
        !Text
        -- ^ action name ("swap", "disburse", …)
        !Text
        -- ^ network ("mainnet", "preprod", "preview")
    | -- | About to connect to the local cardano-node.
      TbeConnect !FilePath
    | -- | N2C handshake's magic matches @intent.network@'s
      --   magic — single source of truth for network is
      --   honoured.
      TbeNetworkOk
        !Text
        -- ^ network name from intent
        !Word32
        -- ^ matching magic
    | -- | N2C handshake reported a magic differing from
      --   @intent.network@'s magic. Terminal event for
      --   exit code 6.
      TbeNetworkMismatch
        !Text
        -- ^ intent.network name
        !Word32
        -- ^ magic implied by intent.network
        !Word32
        -- ^ magic reported by the socket's handshake
    | -- | Number of UTxOs the build will pull from the
      --   chain (wallet TxIn + treasury TxIns + reference
      --   inputs).
      TbeRequiredUtxos !Int
    | -- | Built: bytes, fee lovelace, total collateral
      --   lovelace.
      TbeBuilt !Int !Integer !Integer
    | -- | Re-evaluation summary: replayed N redeemers,
      --   M failed.
      TbeReevaluated !Int !Int
    | -- | One re-evaluated script failure (purpose +
      --   message).
      TbeScriptFail !Text !Text
    | -- | All redeemers re-evaluated cleanly.
      TbeValidationOk
    | -- | At least one redeemer failed re-evaluation.
      TbeValidationFailed
    | -- | Where the hex CBOR went
      --   ('Nothing' = stdout, 'Just' = file path).
      TbeWroteCbor !(Maybe FilePath)
    | -- | Where the summary JSON sidecar went.
      TbeWroteSummary !FilePath
    | -- | The build aborted before producing CBOR.
      TbeAborted !Text
    deriving stock (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderBuildEvent :: BuildEvent -> Text
renderBuildEvent =
    ("tx-build: " <>) . body
  where
    body = \case
        TbeIntentSource Nothing -> "intent <- stdin"
        TbeIntentSource (Just p) ->
            "intent <- " <> T.pack p
        TbeIntentParsed action network ->
            "parsed action="
                <> action
                <> " network="
                <> network
        TbeConnect socket ->
            "connecting to " <> T.pack socket
        TbeNetworkOk network magic ->
            "handshake ok (magic "
                <> tshow magic
                <> " matches intent network="
                <> network
                <> ")"
        TbeNetworkMismatch
            intentName
            intentMagic
            socketMagic ->
                "NETWORK MISMATCH intent declares "
                    <> intentName
                    <> " (magic "
                    <> tshow intentMagic
                    <> "), socket reports magic "
                    <> tshow socketMagic
        TbeRequiredUtxos n ->
            "required utxos: " <> tshow n
        TbeBuilt bytes fee tc ->
            "built "
                <> tshow bytes
                <> " bytes  fee="
                <> tshow fee
                <> "  total_collateral="
                <> tshow tc
        TbeReevaluated total fails ->
            "re-evaluated "
                <> tshow total
                <> " redeemers, "
                <> tshow fails
                <> " failed"
        TbeScriptFail purpose err ->
            "FAIL " <> purpose <> " — " <> err
        TbeValidationOk -> "VALIDATION OK"
        TbeValidationFailed -> "VALIDATION FAILED"
        TbeWroteCbor Nothing -> "cbor -> stdout"
        TbeWroteCbor (Just p) -> "cbor -> " <> T.pack p
        TbeWroteSummary p ->
            "summary -> " <> T.pack p
        TbeAborted msg -> "ABORT " <> msg

{- | Lift a 'Text' sink into a 'BuildEvent' tracer via
'renderBuildEvent'.
-}
buildEventTracer :: Tracer m Text -> Tracer m BuildEvent
buildEventTracer = contramap renderBuildEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
