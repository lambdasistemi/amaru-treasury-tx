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
    ( EnvelopeKind (..)
    , encodeEnvelope
    ) where

import Data.Aeson
    ( ToJSON (..)
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
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)

-- | The envelope flavor manufactured by an @envelope-*@ command.
data EnvelopeKind
    = Tx
    | Witness
    | SignedTx
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
