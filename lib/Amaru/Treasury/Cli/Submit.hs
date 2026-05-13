{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Submit
Description : CLI parser + runner for the @submit@ subcommand
License     : Apache-2.0

Push a signed Conway tx CBOR hex to a local @cardano-node@ over the
N2C LocalTxSubmission protocol. Reuses the node socket / network
configuration owned by @GlobalOpts@; takes the signed CBOR via
@--tx PATH@ (defaults to stdin).
-}
module Amaru.Treasury.Cli.Submit
    ( SubmitOpts (..)
    , submitOptsP
    , runSubmit
    ) where

import Data.ByteString qualified as BS
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
                    <> metavar "PATH"
                    <> help
                        "Path to signed tx CBOR hex (defaults to stdin)"
                )
            )

{- | Run the @submit@ subcommand. Reads the signed CBOR, opens an N2C
session, and submits. On success prints the tx hash to stdout (so it
pipes into downstream tooling) and the outcome line to stderr; on
rejection prints the outcome line to stderr and exits non-zero.
-}
runSubmit :: NetworkMagic -> FilePath -> SubmitOpts -> IO ()
runSubmit magic socketPath SubmitOpts{..} = do
    txHex <- maybe BS.getContents BS.readFile soTxPath
    outcome <- submitSignedTx magic socketPath txHex
    hPutStrLn stderr (T.unpack (renderSubmitOutcome outcome))
    case outcome of
        SubmitAccepted txId -> printTxId txId
        SubmitRejected _ -> exitFailure
        SubmitDecodeFailed _ -> exitFailure

printTxId :: TxId -> IO ()
printTxId = print
