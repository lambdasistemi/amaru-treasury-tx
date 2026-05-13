{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Submit
Description : CLI parser + runner for the @submit@ subcommand
License     : Apache-2.0

Push a signed Conway tx to a local @cardano-node@ over the N2C
LocalTxSubmission protocol. Reuses the node socket / network
configuration owned by @GlobalOpts@; takes the signed payload via:

* @--tx PATH@ — auto-detects raw CBOR hex or cardano-cli envelope JSON.
* @--tx-file PATH@ — cardano-cli muscle-memory alias for the same flag.
* stdin (default) — raw CBOR hex piped from @attach-witness@.
-}
module Amaru.Treasury.Cli.Submit
    ( SubmitOpts (..)
    , submitOptsP
    , runSubmit
    ) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Cardano.Ledger.TxIn (TxId)

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , readEnvelopeOrHex
    , renderEnvelopeError
    )
import Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , renderSubmitOutcome
    , submitSignedTx
    )

{- | Flags for the @submit@ subcommand. The node socket and network
magic come from the top-level @GlobalOpts@; this record only carries
the signed-tx source.
-}
newtype SubmitOpts = SubmitOpts
    { soTxPath :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | Subcommand parser for @submit@.
submitOptsP :: Parser SubmitOpts
submitOptsP =
    SubmitOpts
        <$> optional
            ( strOption
                ( long "tx"
                    <> long "tx-file"
                    <> metavar "PATH"
                    <> help
                        "Signed tx CBOR hex or cardano-cli envelope JSON (defaults to stdin)"
                )
            )

{- | Run the @submit@ subcommand. Reads the signed payload (envelope
or raw hex), opens an N2C session, and submits. On success prints the
tx hash to stdout (so it pipes into downstream tooling) and the
outcome line to stderr; on rejection prints the outcome line and
exits non-zero.
-}
runSubmit :: NetworkMagic -> FilePath -> SubmitOpts -> IO ()
runSubmit magic socketPath SubmitOpts{..} = do
    txHex <- case soTxPath of
        Nothing -> BS.getContents
        Just path ->
            readEnvelopeOrHex TxEnvelope path >>= \case
                Right bs -> pure bs
                Left err -> die (renderEnvelopeError err)
    outcome <- submitSignedTx magic socketPath txHex
    hPutStrLn stderr (T.unpack (renderSubmitOutcome outcome))
    case outcome of
        SubmitAccepted txId -> printTxId txId
        SubmitRejected _ -> exitFailure
        SubmitDecodeFailed _ -> exitFailure
  where
    die :: Text -> IO a
    die msg = do
        hPutStrLn stderr ("submit: " <> T.unpack msg)
        exitFailure

printTxId :: TxId -> IO ()
printTxId = print
