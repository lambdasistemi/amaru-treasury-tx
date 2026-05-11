{- |
Module      : Amaru.Treasury.Build.Trace
Description : Tracer events for the unified tx-build pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Carries the steps the unified @tx-build@ subcommand
takes that affect the produced tx CBOR or requested
sidecar artifacts: 'BuildEventIntentParsed' (the action +
network read from the intent), 'BuildEventNetworkOk' /
'BuildEventNetworkMismatch' (the N2C handshake magic vs
@intent.network@), and report-write events.

Constructor prefix @BuildEvent-@ for "BuildEvent".
-}
module Amaru.Treasury.Build.Trace
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
      BuildEventIntentSource !(Maybe FilePath)
    | -- | Action + network read from the parsed intent.
      --   Surfaces the action the build is about to
      --   construct, sourced from the intent.
      BuildEventIntentParsed
        !Text
        -- ^ action name ("swap", "disburse", …)
        !Text
        -- ^ network ("mainnet", "preprod", "preview")
    | -- | About to connect to the local cardano-node.
      BuildEventConnect !FilePath
    | -- | N2C handshake's magic matches @intent.network@'s
      --   magic — single source of truth for network is
      --   honoured.
      BuildEventNetworkOk
        !Text
        -- ^ network name from intent
        !Word32
        -- ^ matching magic
    | -- | N2C handshake reported a magic differing from
      --   @intent.network@'s magic. Terminal event for
      --   exit code 6.
      BuildEventNetworkMismatch
        !Text
        -- ^ intent.network name
        !Word32
        -- ^ magic implied by intent.network
        !Word32
        -- ^ magic reported by the socket's handshake
    | -- | Number of UTxOs the build will pull from the
      --   chain (wallet TxIn + treasury TxIns + reference
      --   inputs).
      BuildEventRequiredUtxos !Int
    | -- | Built: bytes, fee lovelace, total collateral
      --   lovelace.
      BuildEventBuilt !Int !Integer !Integer
    | -- | Re-evaluation summary: replayed N redeemers,
      --   M failed.
      BuildEventReevaluated !Int !Int
    | -- | One re-evaluated script failure (purpose +
      --   message).
      BuildEventScriptFail !Text !Text
    | -- | All redeemers re-evaluated cleanly.
      BuildEventValidationOk
    | -- | At least one redeemer failed re-evaluation.
      BuildEventValidationFailed
    | -- | Where the hex CBOR went
      --   ('Nothing' = stdout, 'Just' = file path).
      BuildEventWroteCbor !(Maybe FilePath)
    | -- | Where the summary JSON sidecar went.
      BuildEventWroteSummary !FilePath
    | -- | Where the deterministic report JSON sidecar went.
      BuildEventWroteReport !FilePath
    | -- | The requested report JSON sidecar could not be written.
      BuildEventReportWriteFailed !FilePath !Text
    | -- | The build aborted before producing CBOR.
      BuildEventAborted !Text
    deriving stock (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderBuildEvent :: BuildEvent -> Text
renderBuildEvent =
    ("tx-build: " <>) . body
  where
    body = \case
        BuildEventIntentSource Nothing -> "intent <- stdin"
        BuildEventIntentSource (Just p) ->
            "intent <- " <> T.pack p
        BuildEventIntentParsed action network ->
            "parsed action="
                <> action
                <> " network="
                <> network
        BuildEventConnect socket ->
            "connecting to " <> T.pack socket
        BuildEventNetworkOk network magic ->
            "handshake ok (magic "
                <> tshow magic
                <> " matches intent network="
                <> network
                <> ")"
        BuildEventNetworkMismatch
            intentName
            intentMagic
            socketMagic ->
                "NETWORK MISMATCH intent declares "
                    <> intentName
                    <> " (magic "
                    <> tshow intentMagic
                    <> "), socket reports magic "
                    <> tshow socketMagic
        BuildEventRequiredUtxos n ->
            "required utxos: " <> tshow n
        BuildEventBuilt bytes fee tc ->
            "built "
                <> tshow bytes
                <> " bytes  fee="
                <> tshow fee
                <> "  total_collateral="
                <> tshow tc
        BuildEventReevaluated total fails ->
            "re-evaluated "
                <> tshow total
                <> " redeemers, "
                <> tshow fails
                <> " failed"
        BuildEventScriptFail purpose err ->
            "FAIL " <> purpose <> " — " <> err
        BuildEventValidationOk -> "VALIDATION OK"
        BuildEventValidationFailed -> "VALIDATION FAILED"
        BuildEventWroteCbor Nothing -> "cbor -> stdout"
        BuildEventWroteCbor (Just p) -> "cbor -> " <> T.pack p
        BuildEventWroteSummary p ->
            "summary -> " <> T.pack p
        BuildEventWroteReport p ->
            "report -> " <> T.pack p
        BuildEventReportWriteFailed p err ->
            "REPORT WRITE FAILED "
                <> T.pack p
                <> ": "
                <> err
        BuildEventAborted msg -> "ABORT " <> msg

{- | Lift a 'Text' sink into a 'BuildEvent' tracer via
'renderBuildEvent'.
-}
buildEventTracer :: Tracer m Text -> Tracer m BuildEvent
buildEventTracer = contramap renderBuildEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
