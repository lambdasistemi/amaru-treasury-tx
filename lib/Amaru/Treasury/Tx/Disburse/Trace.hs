{- |
Module      : Amaru.Treasury.Tx.Disburse.Trace
Description : Tracer events for the disburse-build pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.Swap.Trace`](Amaru.Treasury.Tx.Swap.Trace.html)
for the disburse subcommand. Every step in the @disburse@
build pipeline that affects the produced transaction CBOR
is a constructor of 'DisburseEvent'. The default sink is
stderr; @--log PATH@ in the CLI redirects to a file.
-}
module Amaru.Treasury.Tx.Disburse.Trace
    ( DisburseEvent (..)
    , renderDisburseEvent
    , disburseEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T

{- | Steps the @disburse@ subcommand takes that affect tx
CBOR or the summary sidecar.
-}
data DisburseEvent
    = -- | Where the intent.json came from
      --   ('Nothing' = stdin, 'Just' = file path).
      DeIntentSource !(Maybe FilePath)
    | -- | About to connect to the local cardano-node.
      DeConnect !FilePath
    | -- | Number of UTxOs the build will pull from the
      --   chain (wallet TxIn + treasury TxIns + reference
      --   inputs).
      DeRequiredUtxos !Int
    | -- | Built: bytes, fee lovelace, total collateral
      --   lovelace.
      DeBuilt !Int !Integer !Integer
    | -- | Re-evaluation summary: replayed N redeemers,
      --   M failed.
      DeReevaluated !Int !Int
    | -- | One re-evaluated script failure (purpose +
      --   message).
      DeScriptFail !Text !Text
    | -- | All redeemers re-evaluated cleanly.
      DeValidationOk
    | -- | At least one redeemer failed re-evaluation.
      DeValidationFailed
    | -- | Where the hex CBOR went
      --   ('Nothing' = stdout, 'Just' = file path).
      DeWroteCbor !(Maybe FilePath)
    | -- | Where the summary JSON sidecar went.
      DeWroteSummary !FilePath
    | -- | The build aborted before producing CBOR.
      DeAborted !Text
    deriving stock (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderDisburseEvent :: DisburseEvent -> Text
renderDisburseEvent =
    ("disburse: " <>) . body
  where
    body = \case
        DeIntentSource Nothing -> "intent <- stdin"
        DeIntentSource (Just p) ->
            "intent <- " <> T.pack p
        DeConnect socket ->
            "connecting to " <> T.pack socket
        DeRequiredUtxos n ->
            "required utxos: " <> tshow n
        DeBuilt bytes fee tc ->
            "built "
                <> tshow bytes
                <> " bytes  fee="
                <> tshow fee
                <> "  total_collateral="
                <> tshow tc
        DeReevaluated total fails ->
            "re-evaluated "
                <> tshow total
                <> " redeemers, "
                <> tshow fails
                <> " failed"
        DeScriptFail purpose err ->
            "FAIL " <> purpose <> " — " <> err
        DeValidationOk -> "VALIDATION OK"
        DeValidationFailed -> "VALIDATION FAILED"
        DeWroteCbor Nothing -> "cbor -> stdout"
        DeWroteCbor (Just p) -> "cbor -> " <> T.pack p
        DeWroteSummary p -> "summary -> " <> T.pack p
        DeAborted msg -> "ABORT " <> msg

{- | Lift a 'Text' sink into a 'DisburseEvent' tracer via
'renderDisburseEvent'.
-}
disburseEventTracer
    :: Tracer m Text -> Tracer m DisburseEvent
disburseEventTracer = contramap renderDisburseEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
