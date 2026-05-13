{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.AttachWitness
Description : CLI parser + runner for the @attach-witness@ subcommand
License     : Apache-2.0

Operators sign treasury transactions out-of-band and hand back one or
more detached vkey witnesses. This subcommand takes the unsigned Conway
transaction emitted by @tx-build@ and merges those witnesses into its
witness set, producing the signed CBOR hex ready for @submit@.

Pipe-friendly defaults: input transaction defaults to stdin and output
defaults to stdout, so the full pipeline is:

@
amaru-treasury-tx tx-build --out - --report - \\
  | amaru-treasury-tx attach-witness --witness HEX --witness HEX \\
  | amaru-treasury-tx submit
@
-}
module Amaru.Treasury.Cli.AttachWitness
    ( AttachWitnessOpts (..)
    , attachWitnessOptsP
    , runAttachWitness
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative
    ( Parser
    , help
    , long
    , many
    , metavar
    , optional
    , short
    , strOption
    )
import System.Exit (exitFailure)
import System.IO
    ( hPutStrLn
    , stderr
    , stdout
    )

import Amaru.Treasury.Tx.AttachWitness
    ( attachWitnesses
    , decodeUnsignedTxHex
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    , renderAttachError
    )

{- | Flags for the @attach-witness@ subcommand.

@awoTxPath@ is the path to the unsigned tx CBOR hex (defaults to
stdin); @awoOutPath@ is where to write the signed CBOR hex (defaults
to stdout); @awoWitnesses@ is the ordered list of detached vkey
witness hex strings to merge.
-}
data AttachWitnessOpts = AttachWitnessOpts
    { awoTxPath :: !(Maybe FilePath)
    , awoOutPath :: !(Maybe FilePath)
    , awoWitnesses :: ![ByteString]
    }
    deriving stock (Eq, Show)

-- | Subcommand parser for @attach-witness@.
attachWitnessOptsP :: Parser AttachWitnessOpts
attachWitnessOptsP =
    AttachWitnessOpts
        <$> optional
            ( strOption
                ( long "tx"
                    <> metavar "PATH"
                    <> help
                        "Path to unsigned tx CBOR hex (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Path to write signed tx CBOR hex (defaults to stdout)"
                )
            )
        <*> many
            ( TE.encodeUtf8 . T.pack
                <$> strOption
                    ( long "witness"
                        <> metavar "HEX"
                        <> help
                            "Detached vkey witness CBOR hex; repeat per signer"
                    )
            )

{- | Run the @attach-witness@ subcommand: read the unsigned
transaction, decode each @--witness@ hex, merge them into the
transaction's witness set, and write the signed CBOR hex.

Exit codes:

* @0@ on success.
* @1@ on any decode error (invalid hex, malformed transaction, or
  malformed witness). The typed error is printed to stderr.
-}
runAttachWitness :: AttachWitnessOpts -> IO ()
runAttachWitness AttachWitnessOpts{..} = do
    txHex <- maybe BS.getContents BS.readFile awoTxPath

    tx <- case decodeUnsignedTxHex txHex of
        Right t -> pure t
        Left err -> die (renderAttachError err)

    wits <- traverseIndexed decodeWitness awoWitnesses

    let signed = encodeSignedTxHex (attachWitnesses (Set.fromList wits) tx)
    case awoOutPath of
        Nothing -> BS.hPut stdout signed >> BS.hPut stdout "\n"
        Just path -> BS.writeFile path signed
  where
    decodeWitness ix hex =
        case decodeVKeyWitnessHex ix hex of
            Right wit -> pure wit
            Left err -> die (renderAttachError err)

    traverseIndexed f xs = traverse (uncurry f) (zip [1 ..] xs)

    die msg = do
        hPutStrLn stderr ("attach-witness: " <> T.unpack msg)
        exitFailure
