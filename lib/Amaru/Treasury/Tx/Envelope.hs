{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.Envelope
Description : cardano-cli compatible JSON envelope for tx and witness CBOR
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

@cardano-cli@ emits transactions and detached witnesses as
single-key-cborHex JSON envelopes:

@
{ "type": "Unwitnessed Tx ConwayEra"
, "description": "Ledger Cddl Format"
, "cborHex": "84ac..."
}
@

Operators who arrive with files produced by @cardano-cli@ should be
able to drop them into @attach-witness@ / @submit@ without first
extracting @cborHex@ by hand. This module reads and writes those
envelopes and, when the path content is not JSON, falls back to the
existing raw CBOR hex format the wider pipeline already uses.

Output uses @"Signed Tx ConwayEra"@ for assembled transactions, the
same type tag @cardano-cli@'s @transaction assemble@ writes; we
mirror it byte-for-byte so the resulting file round-trips through
@cardano-cli conway transaction submit@.
-}
module Amaru.Treasury.Tx.Envelope
    ( -- * Errors
      EnvelopeError (..)
    , renderEnvelopeError

      -- * Types
    , EnvelopeKind (..)
    , envelopeTypeTag

      -- * Read / write
    , readEnvelopeOrHex
    , readEnvelopeHex
    , writeEnvelopeFile
    , renderEnvelopeJson
    ) where

import Control.Exception (IOException, try)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeStrict'
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , defConfig
    , encodePretty'
    , keyOrder
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.IO.Error (ioeGetErrorString)

{- | Failure cases for envelope I/O. Each variant carries
enough context (file path, decode error, era tag) to
render a typed, human-readable diagnostic that names
which boundary rejected the input.
-}
data EnvelopeError
    = -- | The path could not be read. Carries the
      -- offending path and the underlying I/O error.
      EnvelopeReadError !FilePath !Text
    | -- | The content parsed as JSON but did not have the
      -- expected @type@ + @cborHex@ shape.
      EnvelopeShapeError !FilePath !Text
    | -- | The envelope's @type@ field named an era we
      -- don't support (e.g. @ShelleyEra@ or older).
      EnvelopeWrongEra !FilePath !Text
    | -- | The envelope's @type@ field did not match the
      -- expected kind for this entry point (e.g. asked
      -- for a tx envelope, got a witness envelope).
      EnvelopeKindMismatch !FilePath !EnvelopeKind !Text
    | -- | I/O write error when persisting an envelope.
      EnvelopeWriteError !FilePath !Text
    deriving stock (Eq, Show)

{- | Render an 'EnvelopeError' as a single line of human
copy. Naming the offending file path is load-bearing for
operator debugging.
-}
renderEnvelopeError :: EnvelopeError -> Text
renderEnvelopeError = \case
    EnvelopeReadError path err ->
        "failed to read " <> T.pack path <> ": " <> err
    EnvelopeShapeError path err ->
        "envelope JSON in " <> T.pack path <> " is malformed: " <> err
    EnvelopeWrongEra path eraTag ->
        "envelope in "
            <> T.pack path
            <> " names unsupported era: "
            <> eraTag
            <> " (only ConwayEra envelopes are accepted)"
    EnvelopeKindMismatch path expected found ->
        "envelope in "
            <> T.pack path
            <> " has type "
            <> found
            <> " but a "
            <> envelopeTypeTag expected
            <> " was expected"

{- | Which @type@ tag the envelope is required to carry.
The reader uses this to surface a typed error when a
witness file is handed where a transaction file was
expected (or vice versa).
-}
data EnvelopeKind
    = -- | Bodies and signed transactions. Accepts the
      -- three cardano-cli tags an operator might
      -- supply: @Unwitnessed Tx ConwayEra@,
      -- @Witnessed Tx ConwayEra@, and
      -- @Signed Tx ConwayEra@. The wider pipeline
      -- doesn't care which — both bodies and signed
      -- txs are 'ConwayTx' values.
      TxEnvelope
    | -- | Detached vkey witnesses
      -- (@TxWitness ConwayEra@).
      WitnessEnvelope
    | -- | Output envelope written by @attach-witness@
      -- to carry an assembled signed transaction back
      -- out to disk in a shape @cardano-cli conway
      -- transaction submit@ will accept verbatim.
      SignedTxEnvelope
    deriving stock (Eq, Show)

{- | Canonical @type@ tag emitted on write and accepted
on read for each 'EnvelopeKind'. The reader also accepts
the synonyms listed in 'acceptsType'.
-}
envelopeTypeTag :: EnvelopeKind -> Text
envelopeTypeTag = \case
    TxEnvelope -> "Unwitnessed Tx ConwayEra"
    WitnessEnvelope -> "TxWitness ConwayEra"
    SignedTxEnvelope -> "Signed Tx ConwayEra"

{- | Read the @cborHex@ value out of a file that may
contain either a cardano-cli envelope JSON or a raw
hex blob. The auto-detect rule:

* If the (whitespace-trimmed) content starts with @{@,
  parse it as a cardano-cli envelope, validate the
  @type@ field against the requested 'EnvelopeKind',
  and return its @cborHex@.
* Otherwise, return the content verbatim — the wider
  pipeline strips whitespace and decodes base16 itself.

This makes every flag that today takes a hex file path
also accept the equivalent cardano-cli envelope file
with no other change to the caller.
-}
readEnvelopeOrHex
    :: EnvelopeKind -> FilePath -> IO (Either EnvelopeError ByteString)
readEnvelopeOrHex kind path = do
    contents <- readFileSafe path
    pure $ case contents of
        Left err -> Left err
        Right raw
            | looksLikeJson raw -> parseEnvelope kind path raw
            | otherwise -> Right raw

{- | Same as 'readEnvelopeOrHex' but does not accept the
raw-hex fallback. Use this when the caller wants to
require a strict cardano-cli envelope shape (for
example, an @--out-file@ verification path that re-reads
the just-written envelope).
-}
readEnvelopeHex
    :: EnvelopeKind -> FilePath -> IO (Either EnvelopeError ByteString)
readEnvelopeHex kind path = do
    contents <- readFileSafe path
    pure $ case contents of
        Left err -> Left err
        Right raw -> parseEnvelope kind path raw

{- | Write an assembled signed transaction (or any
'EnvelopeKind' the caller chooses) back out as a
cardano-cli compatible envelope JSON. The output is
pretty-printed with the same field ordering
@cardano-cli@ emits (@type@ → @description@ → @cborHex@)
so file diffs against a cardano-cli baseline stay
minimal.
-}
writeEnvelopeFile
    :: EnvelopeKind -> FilePath -> ByteString -> IO (Either EnvelopeError ())
writeEnvelopeFile kind path cborHex = do
    let bytes = renderEnvelopeJson kind cborHex
    res <- try (BS.writeFile path bytes) :: IO (Either IOException ())
    pure $ case res of
        Left err ->
            Left (EnvelopeWriteError path (T.pack (ioeGetErrorString err)))
        Right () -> Right ()

{- | Render a @cborHex@ payload as a cardano-cli style
envelope JSON suitable for writing to disk or for diffing
against a cardano-cli oracle. Pretty-printed with four
space indentation and a trailing newline.
-}
renderEnvelopeJson :: EnvelopeKind -> ByteString -> ByteString
renderEnvelopeJson kind cborHex =
    BSL.toStrict
        ( encodePretty'
            config
            ( object
                [ "type" .= envelopeTypeTag kind
                , "description" .= envelopeDescription kind
                , "cborHex" .= TE.decodeUtf8 cborHex
                ]
            )
        )
        <> "\n"
  where
    config =
        defConfig
            { confIndent = Spaces 4
            , confCompare = keyOrder ["type", "description", "cborHex"]
            , confNumFormat = Generic
            , confTrailingNewline = False
            }

data RawEnvelope = RawEnvelope !Text !Text !Text

instance FromJSON RawEnvelope where
    parseJSON = withObject "TxEnvelope" $ \o -> do
        typ <- o .: "type"
        desc <- o .:? "description"
        hex <- o .: "cborHex"
        pure (RawEnvelope typ (fromMaybe "" desc) hex)

instance ToJSON RawEnvelope where
    toJSON (RawEnvelope typ desc hex) =
        object
            [ "type" .= typ
            , "description" .= desc
            , "cborHex" .= hex
            ]

readFileSafe :: FilePath -> IO (Either EnvelopeError ByteString)
readFileSafe path = do
    res <- try (BS.readFile path) :: IO (Either IOException ByteString)
    pure $ case res of
        Left err ->
            Left
                ( EnvelopeReadError
                    path
                    (T.pack (ioeGetErrorString err))
                )
        Right bs -> Right bs

looksLikeJson :: ByteString -> Bool
looksLikeJson bs = case BS.uncons (BS.dropWhile isAsciiWhitespace bs) of
    Just (c, _) -> c == 0x7B {- '{' -}
    Nothing -> False

isAsciiWhitespace :: Word8 -> Bool
isAsciiWhitespace c =
    c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

parseEnvelope
    :: EnvelopeKind
    -> FilePath
    -> ByteString
    -> Either EnvelopeError ByteString
parseEnvelope kind path raw =
    case eitherDecodeStrict' raw of
        Left err -> Left (EnvelopeShapeError path (T.pack err))
        Right (RawEnvelope typ _desc hex)
            | acceptsType kind typ -> Right (TE.encodeUtf8 hex)
            | not (mentionsConway typ) ->
                Left (EnvelopeWrongEra path typ)
            | otherwise ->
                Left (EnvelopeKindMismatch path kind typ)

acceptsType :: EnvelopeKind -> Text -> Bool
acceptsType TxEnvelope typ =
    typ
        `elem` [ "Unwitnessed Tx ConwayEra"
               , "Witnessed Tx ConwayEra"
               , "Signed Tx ConwayEra"
               ]
acceptsType WitnessEnvelope typ =
    typ == "TxWitness ConwayEra"
acceptsType SignedTxEnvelope typ =
    typ == "Signed Tx ConwayEra"

mentionsConway :: Text -> Bool
mentionsConway = T.isInfixOf "ConwayEra"

envelopeDescription :: EnvelopeKind -> Text
envelopeDescription = \case
    TxEnvelope -> "Ledger Cddl Format"
    WitnessEnvelope -> "Key Witness ShelleyEra"
    SignedTxEnvelope -> "Ledger Cddl Format"
