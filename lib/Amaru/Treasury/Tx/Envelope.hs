{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.Envelope
Description : cardano-cli transaction envelope encoding
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helpers for translating the raw CBOR hex used by the Amaru
pipeline into the JSON text-envelope shape emitted by @cardano-cli@.
The byte layout is pinned by
@test/fixtures/106-cardano-cli-oracle/@.
-}
module Amaru.Treasury.Tx.Envelope
    ( EnvelopeError (..)
    , EnvelopeKind (..)
    , decodeEnvelope
    , encodeEnvelope
    , renderEnvelopeError
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( ToJSON (..)
    , Value (..)
    , eitherDecodeStrict'
    , object
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (Spaces)
    , defConfig
    , encodePretty'
    , keyOrder
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8)
import Numeric (showHex)

-- | The envelope flavor manufactured by an @envelope-*@ command.
data EnvelopeKind
    = Tx
    | Witness
    | SignedTx
    deriving stock (Eq, Show)

-- | Decode-side failures for @cardano-cli@ JSON text envelopes.
data EnvelopeError
    = EnvelopeInputNotJsonObject {envelopeFirstByte :: !(Maybe Word8)}
    | EnvelopeMalformedJson !Text
    | EnvelopeMissingField !Text
    | EnvelopeWrongFieldType !Text
    | EnvelopeWrongEra !Text
    deriving stock (Eq, Show)

data Envelope = Envelope
    { envelopeType :: !Text
    , envelopeDescription :: !Text
    , envelopeCborHex :: !Text
    }

instance ToJSON Envelope where
    toJSON Envelope{envelopeType, envelopeDescription, envelopeCborHex} =
        object
            [ "type" .= envelopeType
            , "description" .= envelopeDescription
            , "cborHex" .= envelopeCborHex
            ]

{- | Encode raw CBOR hex as a @cardano-cli@ JSON text envelope.

The encoder trims trailing ASCII whitespace from the input before it
is placed in @cborHex@. This matches pipe usage where upstream commands
usually write a final newline, while preserving any internal bytes
verbatim.
-}
encodeEnvelope :: EnvelopeKind -> ByteString -> ByteString
encodeEnvelope kind =
    BSL.toStrict
        . encodePretty' envelopeConfig
        . envelope kind
        . trimTrailingAsciiWhitespace

envelope :: EnvelopeKind -> ByteString -> Envelope
envelope kind rawHex =
    Envelope
        { envelopeType = envelopeKindType kind
        , envelopeDescription = envelopeKindDescription kind
        , envelopeCborHex = TE.decodeUtf8With lenientDecode rawHex
        }

envelopeKindType :: EnvelopeKind -> Text
envelopeKindType = \case
    Tx -> "Tx ConwayEra"
    Witness -> "TxWitness ConwayEra"
    SignedTx -> "Tx ConwayEra"

envelopeKindDescription :: EnvelopeKind -> Text
envelopeKindDescription = \case
    Tx -> "Ledger Cddl Format"
    Witness -> "Key Witness ShelleyEra"
    SignedTx -> "Ledger Cddl Format"

envelopeConfig :: Config
envelopeConfig =
    defConfig
        { confIndent = Spaces 4
        , confCompare =
            keyOrder
                [ "type"
                , "description"
                , "cborHex"
                ]
        , confTrailingNewline = True
        }

trimTrailingAsciiWhitespace :: ByteString -> ByteString
trimTrailingAsciiWhitespace =
    BS.dropWhileEnd
        ( \byte ->
            byte == 0x20
                || byte == 0x09
                || byte == 0x0a
                || byte == 0x0d
        )

{- | Extract raw CBOR hex from a @cardano-cli@ JSON text envelope.

The decoder accepts any envelope whose @type@ string contains
@ConwayEra@, ignores @description@ and any extra top-level keys, and
returns the @cborHex@ value followed by exactly one trailing newline so
the result composes with the existing raw-hex commands.
-}
decodeEnvelope :: ByteString -> Either EnvelopeError ByteString
decodeEnvelope raw = do
    requireObjectStart raw
    value <-
        case eitherDecodeStrict' raw of
            Left err -> Left (EnvelopeMalformedJson (T.pack err))
            Right decoded -> Right decoded
    fields <-
        case value of
            Object objectFields -> Right objectFields
            _ -> Left (EnvelopeInputNotJsonObject (firstNonWhitespaceByte raw))
    typ <- stringField "type" fields
    unless ("ConwayEra" `T.isInfixOf` typ) $
        Left (EnvelopeWrongEra typ)
    cborHex <- stringField "cborHex" fields
    Right (TE.encodeUtf8 cborHex <> "\n")

renderEnvelopeError :: EnvelopeError -> Text
renderEnvelopeError = \case
    EnvelopeInputNotJsonObject Nothing ->
        "expected a cardano-cli JSON envelope object starting with `{`; input was empty"
    EnvelopeInputNotJsonObject (Just byte) ->
        "expected a cardano-cli JSON envelope object starting with `{`; first non-whitespace byte was 0x"
            <> hexByte byte
    EnvelopeMalformedJson err ->
        "invalid cardano-cli JSON envelope: " <> err
    EnvelopeMissingField field ->
        "invalid cardano-cli JSON envelope: missing string field `"
            <> field
            <> "`"
    EnvelopeWrongFieldType field ->
        "invalid cardano-cli JSON envelope: field `"
            <> field
            <> "` must be a string"
    EnvelopeWrongEra typ ->
        "unsupported cardano-cli envelope era in type `"
            <> typ
            <> "`; expected ConwayEra"

requireObjectStart :: ByteString -> Either EnvelopeError ()
requireObjectStart raw =
    case firstNonWhitespaceByte raw of
        Just 0x7b -> Right ()
        byte -> Left (EnvelopeInputNotJsonObject byte)

firstNonWhitespaceByte :: ByteString -> Maybe Word8
firstNonWhitespaceByte =
    BS.find (not . isJsonWhitespace)

isJsonWhitespace :: Word8 -> Bool
isJsonWhitespace byte =
    byte == 0x20
        || byte == 0x09
        || byte == 0x0a
        || byte == 0x0d

stringField
    :: Text
    -> KeyMap.KeyMap Value
    -> Either EnvelopeError Text
stringField field fields =
    case KeyMap.lookup (Key.fromText field) fields of
        Nothing -> Left (EnvelopeMissingField field)
        Just (String value) -> Right value
        Just _ -> Left (EnvelopeWrongFieldType field)

hexByte :: Word8 -> Text
hexByte byte =
    let rendered = showHex byte ""
    in  T.pack $
            case rendered of
                [_] -> '0' : rendered
                _ -> rendered
