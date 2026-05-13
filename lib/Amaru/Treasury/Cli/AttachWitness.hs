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

For operators arriving with @cardano-cli@ files on disk, the same
command also reads cardano-cli envelope JSON for the tx body
(@--tx-body-file@) and each detached witness (@--witness-file@), and
optionally writes the assembled result as a cardano-cli
@Signed Tx ConwayEra@ envelope (@--out-file@) so it can be fed
verbatim into @cardano-cli conway transaction submit@.
-}
module Amaru.Treasury.Cli.AttachWitness
    ( AttachWitnessOpts (..)
    , attachWitnessOptsP
    , runAttachWitness
    ) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
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
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , readEnvelopeOrHex
    , renderEnvelopeError
    , writeEnvelopeFile
    )

{- | Source of the unsigned transaction body. Operators
either supply it inline (hex on stdin or a hex/envelope
file via @--tx@) or via the cardano-cli alias
@--tx-body-file@.
-}
data TxBodySource
    = TxBodyStdin
    | -- | Path accepted by both @--tx@ and
      -- @--tx-body-file@. The reader auto-detects
      -- envelope JSON vs raw hex.
      TxBodyFromPath !FilePath
    deriving stock (Eq, Show)

{- | One witness contribution: either inline hex from
@--witness HEX@ or a path to a cardano-cli envelope file
from @--witness-file PATH@. Order is preserved across
the flag types so error messages can reliably name "the
3rd witness".
-}
data WitnessSource
    = WitnessHex !ByteString
    | WitnessFromPath !FilePath
    deriving stock (Eq, Show)

{- | Destination for the signed transaction. Either a
raw-hex file (@--out PATH@), a cardano-cli
@Signed Tx ConwayEra@ envelope (@--out-file PATH@), or
stdout when neither is set (the pipe-friendly default).
-}
data SignedTxSink
    = SinkStdout
    | SinkHexPath !FilePath
    | SinkEnvelopePath !FilePath
    deriving stock (Eq, Show)

{- | Flags for the @attach-witness@ subcommand. The
record carries both the pipe-friendly form and the
cardano-cli-compatible @--tx-body-file@/@--witness-file@/
@--out-file@ form; the runner reconciles them.
-}
data AttachWitnessOpts = AttachWitnessOpts
    { awoTxBody :: !TxBodySource
    , awoWitnesses :: ![WitnessSource]
    , awoSink :: !SignedTxSink
    }
    deriving stock (Eq, Show)

-- | Subcommand parser for @attach-witness@.
attachWitnessOptsP :: Parser AttachWitnessOpts
attachWitnessOptsP =
    AttachWitnessOpts
        <$> txBodyP
        <*> witnessesP
        <*> sinkP

txBodyP :: Parser TxBodySource
txBodyP =
    maybe TxBodyStdin TxBodyFromPath
        <$> optional
            ( strOption
                ( long "tx"
                    <> long "tx-body-file"
                    <> metavar "PATH"
                    <> help
                        "Unsigned tx CBOR hex or cardano-cli envelope JSON (defaults to stdin)"
                )
            )

witnessesP :: Parser [WitnessSource]
witnessesP =
    many $
        WitnessHex
            . TE.encodeUtf8
            . T.pack
            <$> strOption
                ( long "witness"
                    <> metavar "HEX"
                    <> help
                        "Detached vkey witness CBOR hex; repeat per signer"
                )
            <|> WitnessFromPath
                <$> strOption
                    ( long "witness-file"
                        <> metavar "PATH"
                        <> help
                            "Path to cardano-cli TxWitness ConwayEra envelope JSON; repeat per signer"
                    )

sinkP :: Parser SignedTxSink
sinkP =
    fromMaybe SinkStdout
        <$> optional
            ( SinkHexPath
                <$> strOption
                    ( long "out"
                        <> short 'o'
                        <> metavar "PATH"
                        <> help
                            "Write signed tx CBOR hex to PATH (defaults to stdout)"
                    )
                <|> SinkEnvelopePath
                    <$> strOption
                        ( long "out-file"
                            <> metavar "PATH"
                            <> help
                                "Write a cardano-cli Signed Tx ConwayEra envelope JSON to PATH"
                        )
            )

{- | Run the @attach-witness@ subcommand: read the unsigned
transaction (envelope or raw hex), decode each witness
(envelope or inline hex), merge them into the
transaction's witness set, and write the signed result.

Exit codes:

* @0@ on success.
* @1@ on any decode error. The typed error names the
  failing path or witness index.
-}
runAttachWitness :: AttachWitnessOpts -> IO ()
runAttachWitness AttachWitnessOpts{..} = do
    txHex <- readTxBody awoTxBody
    tx <- case decodeUnsignedTxHex txHex of
        Right t -> pure t
        Left err -> die (renderAttachError err)

    wits <- traverseIndexed readWitness awoWitnesses

    let signed = encodeSignedTxHex (attachWitnesses (Set.fromList wits) tx)
    writeSink awoSink signed
  where
    readTxBody TxBodyStdin = BS.getContents
    readTxBody (TxBodyFromPath path) =
        readEnvelopeOrHex TxEnvelope path >>= \case
            Right bs -> pure bs
            Left err -> die (renderEnvelopeError err)

    readWitness ix source = do
        hex <- case source of
            WitnessHex h -> pure h
            WitnessFromPath path ->
                readEnvelopeOrHex WitnessEnvelope path >>= \case
                    Right bs -> pure bs
                    Left err -> die (renderEnvelopeError err)
        case decodeVKeyWitnessHex ix hex of
            Right wit -> pure wit
            Left err -> die (renderAttachError err)

    writeSink SinkStdout bs = BS.hPut stdout bs >> BS.hPut stdout "\n"
    writeSink (SinkHexPath path) bs = BS.writeFile path bs
    writeSink (SinkEnvelopePath path) bs =
        writeEnvelopeFile SignedTxEnvelope path bs >>= \case
            Right () -> pure ()
            Left err -> die (renderEnvelopeError err)

    traverseIndexed f xs = traverse (uncurry f) (zip [1 ..] xs)

    die :: Text -> IO a
    die msg = do
        hPutStrLn stderr ("attach-witness: " <> T.unpack msg)
        exitFailure
