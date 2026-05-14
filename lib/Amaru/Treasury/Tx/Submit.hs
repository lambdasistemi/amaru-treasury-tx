{- |
Module      : Amaru.Treasury.Tx.Submit
Description : Submit a signed Conway transaction over N2C
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin wrapper around 'Cardano.Node.Client.N2C.Submitter.mkN2CSubmitter'
that owns the N2C connection lifecycle. Used by the @submit@ CLI
subcommand to push a signed Conway transaction to a local
@cardano-node@ via its LocalTxSubmission mini-protocol, returning
either the submitted tx hash or the node's rejection reason.

The CBOR codec lives in 'Amaru.Treasury.Tx.AttachWitness'
('decodeUnsignedTxHex'); a signed tx is still a 'ConwayTx', just one
with a populated witness set. Reusing that decoder keeps the submit
path symmetric with the build / attach-witness path: every hop on the
pipeline speaks the same raw CBOR hex format.
-}
module Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , submitSignedTx
    , renderSubmitOutcome
    , renderTxId
    ) where

import Control.Concurrent.Async (withAsync)
import Control.Exception (SomeException, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as B8
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Ouroboros.Network.Magic (NetworkMagic)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )

import Amaru.Treasury.Tx.AttachWitness
    ( AttachError
    , decodeUnsignedTxHex
    , renderAttachError
    )

{- | Result of a submit attempt.

* 'SubmitDecodeFailed' — the CBOR hex did not decode as a Conway tx.
* 'SubmitRejected' — the node accepted the protocol handshake but
  rejected the transaction. Carries the rejection reason as the node
  surfaced it.
* 'SubmitAccepted' — the node enqueued the tx; carries the tx hash.
-}
data SubmitOutcome
    = SubmitDecodeFailed !AttachError
    | SubmitRejected !Text
    | SubmitAccepted !TxId
    deriving stock (Show)

{- | Submit a signed transaction by hex.

Opens a fresh N2C session against @socketPath@ on @magic@, drives the
LocalStateQuery + LocalTxSubmission mux long enough to push the tx,
and closes the session. Returns the outcome typed; the caller renders
it via 'renderSubmitOutcome'.

The LSQ channel is created and never used (the submit path does not
query the chain). The Cardano client requires both protocols to
coexist on the same session — 'runNodeClient' multiplexes them.
-}
submitSignedTx
    :: NetworkMagic
    -> FilePath
    -> ByteString
    -> IO SubmitOutcome
submitSignedTx magic socketPath txHex = do
    case decodeUnsignedTxHex txHex of
        Left err ->
            pure (SubmitDecodeFailed err)
        Right tx -> do
            lsq <- newLSQChannel 1
            ltxs <- newLTxSChannel 1
            let connect = do
                    r <- runNodeClient magic socketPath lsq ltxs
                    case r of
                        Right () -> pure ()
                        Left e -> throwIO (e :: SomeException)
            withAsync connect $ \_ -> do
                let submitter = mkN2CSubmitter ltxs
                result <- submitTx submitter tx
                pure $ case result of
                    Submitted _ ->
                        SubmitAccepted (txIdTx tx)
                    Rejected reason ->
                        SubmitRejected (decodeUtf8Lenient reason)

{- | Render a 'SubmitOutcome' as a single human-readable line. The
@submit@ CLI prints this to stderr; the tx hash also goes to stdout
on success so it is pipeable into downstream tools.
-}
renderSubmitOutcome :: SubmitOutcome -> Text
renderSubmitOutcome = \case
    SubmitDecodeFailed err ->
        "submit: " <> renderAttachError err
    SubmitRejected reason ->
        "submit: node rejected transaction: " <> reason
    SubmitAccepted txId ->
        "submit: accepted " <> renderTxId txId

{- | Render a 'TxId' as a bare lowercase base16 hex string (64 chars).
Pipe-friendly: no surrounding @TxId {…}@ or @SafeHash …@ noise.
-}
renderTxId :: TxId -> Text
renderTxId (TxId h) =
    TE.decodeUtf8 (B16.encode (hashToBytes (extractHash h)))

decodeUtf8Lenient :: B8.ByteString -> Text
decodeUtf8Lenient =
    TE.decodeUtf8With (\_ _ -> Just '?')
