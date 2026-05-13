{- |
Module      : Amaru.Treasury.Tx.AttachWitness
Description : Merge detached vkey witnesses into a Conway transaction
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Operators sign treasury transactions out-of-band (hardware wallet,
external signing tool) and hand back a list of detached vkey witnesses.
This module takes the unsigned Conway transaction emitted by
@tx-build@ and merges those witnesses into its witness set, preserving
the body and aux-data bytes so the @aux_data_hash@ and
@script_data_hash@ remain valid.

All inputs and outputs are raw CBOR hex; no JSON envelopes are used.
-}
module Amaru.Treasury.Tx.AttachWitness
    ( -- * Errors
      AttachError (..)
    , renderAttachError

      -- * Decoders / encoders
    , decodeUnsignedTxHex
    , decodeVKeyWitnessHex
    , encodeSignedTxHex

      -- * Witness merge
    , attachWitnesses
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Lens.Micro ((%~), (&))

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (addrTxWitsL)
import Cardano.Ledger.Binary
    ( Annotator
    , DecCBOR (..)
    , Decoder
    , DecoderError
    , decodeFullAnnotator
    , decodeListLenOf
    , decodeWord
    , serialize
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (witsTxL)
import Cardano.Ledger.Keys (KeyRole (..), WitVKey)
import Cardano.Node.Client.Ledger (ConwayTx)

{- | Failure cases for witness attachment. Each variant
carries enough context to render a typed, human-readable
diagnostic.
-}
data AttachError
    = -- | The transaction hex did not decode as a Conway
      -- transaction.
      AttachDecodeTxFailed !Text
    | -- | A witness hex did not decode as a vkey witness.
      -- Carries the 1-based witness index.
      AttachDecodeWitnessFailed !Int !Text
    | -- | A hex blob was not valid base16. Carries the
      -- offending blob's label.
      AttachInvalidHex !Text !Text
    deriving stock (Eq, Show)

{- | Render an 'AttachError' as a single line of human
copy. Used by the CLI when surfacing a non-zero exit.
-}
renderAttachError :: AttachError -> Text
renderAttachError = \case
    AttachDecodeTxFailed err ->
        "failed to decode unsigned transaction: " <> err
    AttachDecodeWitnessFailed ix err ->
        "failed to decode witness #"
            <> T.pack (show ix)
            <> ": "
            <> err
    AttachInvalidHex label err ->
        "invalid base16 in " <> label <> ": " <> err

{- | Decode a Conway transaction from base16-encoded
CBOR hex. Trailing whitespace (newlines, spaces) is
stripped before decoding so file or pipe input that ends
with a newline still parses.
-}
decodeUnsignedTxHex :: ByteString -> Either AttachError ConwayTx
decodeUnsignedTxHex hex = do
    raw <- decodeHexBlob "unsigned transaction" hex
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (BSL.fromStrict raw) of
        Right tx -> Right tx
        Left err ->
            Left
                (AttachDecodeTxFailed (renderDecoderError err))

{- | Decode a detached vkey witness from base16-encoded
CBOR hex. Accepts both the raw ledger 'WitVKey' two-array
(@[vkey, signature]@) and the cardano-cli @KeyWitness@
envelope (@[0, [vkey, signature]]@) that
@cardano-cli transaction witness@ emits. The leading
@0@ tag identifies a vkey witness; the only other tags
in the cardano-cli encoding are bootstrap / Byron, which
@attach-witness@ rejects.

@ix@ is the 1-based witness index; it is woven into
decode-error messages so the operator can identify which
@--witness@ argument was rejected.
-}
decodeVKeyWitnessHex
    :: Int -> ByteString -> Either AttachError (WitVKey Witness)
decodeVKeyWitnessHex ix hex = do
    raw <- decodeHexBlob (witnessLabel ix) hex
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "KeyWitness"
        keyWitnessDecoder
        (BSL.fromStrict raw) of
        Right wit -> Right wit
        Left err ->
            Left
                ( AttachDecodeWitnessFailed
                    ix
                    (renderDecoderError err)
                )

{- | Decoder that recognises both the raw 'WitVKey' shape
and the @[tag, WitVKey]@ envelope used by
@cardano-cli transaction witness@. Only tag @0@ (vkey
witness) is accepted; bootstrap and Byron witness tags
are rejected as out-of-scope for the swap pipeline.
-}
keyWitnessDecoder :: Decoder s (Annotator (WitVKey Witness))
keyWitnessDecoder = do
    decodeListLenOf 2
    tag <- decodeWord
    case tag of
        0 -> decCBOR
        _ -> fail ("unsupported KeyWitness tag: " <> show tag)

{- | Merge a set of vkey witnesses into the
transaction's witness set. Duplicate entries (same vkey)
are removed by 'Set' semantics — attaching the same
witness twice is a no-op.

The body, aux-data, redeemers, scripts, and the
@is_valid@ flag are not touched, so the transaction's
body hash and aux-data hash are unchanged.
-}
attachWitnesses :: Set (WitVKey Witness) -> ConwayTx -> ConwayTx
attachWitnesses wits tx =
    tx & witsTxL . addrTxWitsL %~ Set.union wits

{- | Re-encode a (now signed) Conway transaction as
lowercase base16 CBOR hex.
-}
encodeSignedTxHex :: ConwayTx -> ByteString
encodeSignedTxHex tx =
    B16.encode
        (BSL.toStrict (serialize (eraProtVerLow @ConwayEra) tx))

decodeHexBlob :: Text -> ByteString -> Either AttachError ByteString
decodeHexBlob label hex =
    case B16.decode (stripWhitespace hex) of
        Right raw -> Right raw
        Left err -> Left (AttachInvalidHex label (T.pack err))

stripWhitespace :: ByteString -> ByteString
stripWhitespace =
    BS.filter (`notElem` whitespaceBytes)

whitespaceBytes :: [Word8]
whitespaceBytes = [0x20, 0x09, 0x0a, 0x0d]

renderDecoderError :: DecoderError -> Text
renderDecoderError = T.pack . show

witnessLabel :: Int -> Text
witnessLabel ix = "witness #" <> T.pack (show ix)
