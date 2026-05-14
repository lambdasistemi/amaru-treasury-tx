{- |
Module      : Amaru.Treasury.Cli.Envelope
Description : CLI runners for cardano-cli envelope filters
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin stdin/stdout wrappers over 'Amaru.Treasury.Tx.Envelope'.
-}
module Amaru.Treasury.Cli.Envelope
    ( runEnvelope
    , runEnvelopeFilter
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import System.IO (stdout)

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind
    , encodeEnvelope
    )

-- | Pure filter used by the three wrapper commands.
runEnvelopeFilter :: EnvelopeKind -> ByteString -> ByteString
runEnvelopeFilter = encodeEnvelope

-- | Read raw hex from stdin and write the corresponding envelope.
runEnvelope :: EnvelopeKind -> IO ()
runEnvelope kind = do
    rawHex <- BS.getContents
    BS.hPut stdout (runEnvelopeFilter kind rawHex)
