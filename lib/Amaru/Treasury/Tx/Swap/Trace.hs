{- |
Module      : Amaru.Treasury.Tx.Swap.Trace
Description : Tracer events for the swap-build pipeline
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors the wizard's
'Amaru.Treasury.Tx.SwapWizard.Trace.WizardEvent' shape: every
step in the @swap@ subcommand that affects the produced
transaction CBOR is a constructor here, and the rendered
output goes through a typed @'Tracer' IO 'SwapEvent'@. The
default sink is stderr; a @--log PATH@ flag in the CLI
redirects the trace to a file.
-}
module Amaru.Treasury.Tx.Swap.Trace
    ( SwapEvent (..)
    , renderSwapEvent
    , swapEventTracer
    ) where

import Control.Tracer (Tracer (..), contramap)
import Data.Text (Text)
import Data.Text qualified as T

-- | Steps the @swap@ subcommand takes that affect tx CBOR.
data SwapEvent
    = -- | Where the intent.json came from
      --   ('Nothing' = stdin, 'Just' = file path).
      SeIntentSource !(Maybe FilePath)
    | -- | About to connect to the local cardano-node.
      SeConnect !FilePath
    | -- | Number of UTxOs the build will pull from the chain
      --   (wallet TxIn + treasury TxIns + reference inputs).
      SeRequiredUtxos !Int
    | -- | Built: bytes, fee lovelace, total collateral lovelace.
      SeBuilt !Int !Integer !Integer
    | -- | Re-evaluation summary: replayed N redeemers, M failed.
      SeReevaluated !Int !Int
    | -- | One re-evaluated script failure (purpose + message).
      SeScriptFail !Text !Text
    | -- | All redeemers re-evaluated cleanly.
      SeValidationOk
    | -- | At least one redeemer failed re-evaluation.
      SeValidationFailed
    | -- | Where the hex CBOR went
      --   ('Nothing' = stdout, 'Just' = file path).
      SeWroteCbor !(Maybe FilePath)
    | -- | The build aborted before producing CBOR.
      SeAborted !Text
    deriving (Eq, Show)

-- | Single-line, prefix-tagged rendering for log output.
renderSwapEvent :: SwapEvent -> Text
renderSwapEvent =
    ("swap: " <>) . body
  where
    body = \case
        SeIntentSource Nothing -> "intent <- stdin"
        SeIntentSource (Just p) -> "intent <- " <> T.pack p
        SeConnect socket ->
            "connecting to " <> T.pack socket
        SeRequiredUtxos n ->
            "required utxos: " <> tshow n
        SeBuilt bytes fee tc ->
            "built "
                <> tshow bytes
                <> " bytes  fee="
                <> tshow fee
                <> "  total_collateral="
                <> tshow tc
        SeReevaluated total fails ->
            "re-evaluated "
                <> tshow total
                <> " redeemers, "
                <> tshow fails
                <> " failed"
        SeScriptFail purpose err ->
            "FAIL " <> purpose <> " — " <> err
        SeValidationOk -> "VALIDATION OK"
        SeValidationFailed -> "VALIDATION FAILED"
        SeWroteCbor Nothing -> "cbor -> stdout"
        SeWroteCbor (Just p) -> "cbor -> " <> T.pack p
        SeAborted msg -> "ABORT " <> msg

-- | Lift a 'Text' sink into a 'SwapEvent' tracer via 'renderSwapEvent'.
swapEventTracer :: Tracer m Text -> Tracer m SwapEvent
swapEventTracer = contramap renderSwapEvent

tshow :: (Show a) => a -> Text
tshow = T.pack . show
