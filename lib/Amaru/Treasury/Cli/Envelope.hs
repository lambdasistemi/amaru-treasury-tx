{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.Envelope
Description : CLI runners for cardano-cli envelope filters
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin stdin/stdout wrappers over 'Amaru.Treasury.Tx.Envelope'.
-}
module Amaru.Treasury.Cli.Envelope
    ( DeEnvelopeFilterResult (..)
    , runDeEnvelope
    , runDeEnvelopeFilter
    , runEnvelope
    , runEnvelopeFilter
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Exit
    ( ExitCode (..)
    , exitWith
    )
import System.IO
    ( stderr
    , stdout
    )

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind
    , decodeEnvelope
    , encodeEnvelope
    , renderEnvelopeError
    )

data DeEnvelopeFilterResult = DeEnvelopeFilterResult
    { defrExitCode :: !ExitCode
    , defrStdout :: !ByteString
    , defrStderr :: !Text
    }
    deriving stock (Eq, Show)

-- | Pure filter used by the three wrapper commands.
runEnvelopeFilter :: EnvelopeKind -> ByteString -> ByteString
runEnvelopeFilter = encodeEnvelope

-- | Read raw hex from stdin and write the corresponding envelope.
runEnvelope :: EnvelopeKind -> IO ()
runEnvelope kind = do
    rawHex <- BS.getContents
    BS.hPut stdout (runEnvelopeFilter kind rawHex)

-- | Pure filter used by @de-envelope@.
runDeEnvelopeFilter :: ByteString -> DeEnvelopeFilterResult
runDeEnvelopeFilter rawEnvelope =
    case decodeEnvelope rawEnvelope of
        Right rawHex ->
            DeEnvelopeFilterResult
                { defrExitCode = ExitSuccess
                , defrStdout = rawHex
                , defrStderr = ""
                }
        Left err ->
            DeEnvelopeFilterResult
                { defrExitCode = ExitFailure 1
                , defrStdout = ""
                , defrStderr =
                    "de-envelope: " <> renderEnvelopeError err <> "\n"
                }

-- | Read a JSON text envelope from stdin and write raw hex to stdout.
runDeEnvelope :: IO ()
runDeEnvelope = do
    rawEnvelope <- BS.getContents
    let DeEnvelopeFilterResult{defrExitCode, defrStdout, defrStderr} =
            runDeEnvelopeFilter rawEnvelope
    BS.hPut stdout defrStdout
    TIO.hPutStr stderr defrStderr
    case defrExitCode of
        ExitSuccess -> pure ()
        ExitFailure{} -> exitWith defrExitCode
