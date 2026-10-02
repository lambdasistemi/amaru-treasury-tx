{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.Envelope
Description : CLI runners for cardano-cli envelope filters
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin file-or-stdio wrappers over 'Amaru.Treasury.Tx.Envelope'.
Each command reads @--in FILE@ (default stdin) and writes
@--out FILE@ (default stdout).
-}
module Amaru.Treasury.Cli.Envelope
    ( DeEnvelopeFilterResult (..)
    , EnvelopeIO (..)
    , envelopeIOP
    , runDeEnvelope
    , runDeEnvelopeFilter
    , runEnvelope
    , runEnvelopeFilter
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , strOption
    )
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

-- | Input and output paths shared by the four envelope commands.
data EnvelopeIO = EnvelopeIO
    { envelopeInPath :: !(Maybe FilePath)
    -- ^ 'Nothing' reads stdin.
    , envelopeOutPath :: !(Maybe FilePath)
    -- ^ 'Nothing' writes stdout.
    }
    deriving stock (Eq, Show)

-- | @--in FILE@ and @--out FILE@, both optional.
envelopeIOP :: Parser EnvelopeIO
envelopeIOP =
    EnvelopeIO
        <$> optional
            ( strOption
                ( long "in"
                    <> metavar "FILE"
                    <> help "Read input from FILE (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> metavar "FILE"
                    <> help "Write output to FILE (defaults to stdout)"
                )
            )

-- | Result of the pure @de-envelope@ filter.
data DeEnvelopeFilterResult = DeEnvelopeFilterResult
    { defrExitCode :: !ExitCode
    , defrStdout :: !ByteString
    , defrStderr :: !Text
    }
    deriving stock (Eq, Show)

-- | Pure filter used by the three wrapper commands.
runEnvelopeFilter :: EnvelopeKind -> ByteString -> ByteString
runEnvelopeFilter = encodeEnvelope

-- | Read raw hex and write the corresponding envelope.
runEnvelope :: EnvelopeKind -> EnvelopeIO -> IO ()
runEnvelope kind io = do
    rawHex <- readInput io
    writeOutput io (runEnvelopeFilter kind rawHex)

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

{- | Read a JSON text envelope and write raw hex. A rejected
envelope writes only the diagnostic to stderr and never opens
the output.
-}
runDeEnvelope :: EnvelopeIO -> IO ()
runDeEnvelope io = do
    rawEnvelope <- readInput io
    let DeEnvelopeFilterResult{defrExitCode, defrStdout, defrStderr} =
            runDeEnvelopeFilter rawEnvelope
    case defrExitCode of
        ExitSuccess -> writeOutput io defrStdout
        ExitFailure{} -> pure ()
    TIO.hPutStr stderr defrStderr
    case defrExitCode of
        ExitSuccess -> pure ()
        ExitFailure{} -> exitWith defrExitCode

readInput :: EnvelopeIO -> IO ByteString
readInput = maybe BS.getContents BS.readFile . envelopeInPath

writeOutput :: EnvelopeIO -> ByteString -> IO ()
writeOutput io bytes =
    maybe (BS.hPut stdout bytes) (`BS.writeFile` bytes) $
        envelopeOutPath io
