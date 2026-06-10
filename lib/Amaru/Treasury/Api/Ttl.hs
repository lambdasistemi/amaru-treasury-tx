{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.Ttl
Description : RDF Turtle lattice for a freshly built unsigned tx (#357)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Projects an unsigned transaction (as the cbor hex a @POST
\/v1\/build\/*@ response carries) onto the same RDF lattice the
history surface builds: the shared Turtle prefix block, the
treasury entity overlay from verified metadata, and the ledger
body triples emitted by the upstream @cq-rdf@ executable.

Mirrors 'Amaru.Treasury.History.Sparql.buildHistoryLattice' for
a single not-yet-submitted transaction: same prefix vocabulary,
same 'metadataEntityTriples' overlay, same @cq-rdf body@
emitter shelled out against a temp file.
-}
module Amaru.Treasury.Api.Ttl
    ( buildTxLattice
    ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

import Amaru.Treasury.History.Sparql
    ( metadataEntityTriples
    , turtlePrefixLines
    )
import Amaru.Treasury.Metadata (TreasuryMetadata)

{- | Emit the RDF Turtle lattice of one unsigned transaction:
prefix block, metadata entity overlay, then the @cq-rdf body@
triples of the transaction itself.

'Nothing' when the hex does not decode or @cq-rdf@ is
unavailable or exits non-zero — the TTL is a best-effort
projection (like the build-time graph-effect) and must never
fail the build response that carries it.
-}
buildTxLattice
    :: Maybe TreasuryMetadata
    -> Text
    -- ^ Unsigned tx cbor hex, as carried by the build response.
    -> IO (Maybe Text)
buildTxLattice metadata cborHex =
    case decodeHex cborHex of
        Nothing -> pure Nothing
        Just bytes ->
            withSystemTempDirectory "amaru-build-ttl" $ \dir -> do
                let txPath = dir </> "tx.cbor"
                result <-
                    try $ do
                        BS.writeFile txPath bytes
                        readProcessWithExitCode
                            "cq-rdf"
                            ["body", txPath]
                            ""
                pure $ case result of
                    Left (_ :: IOException) -> Nothing
                    Right (ExitSuccess, out, _) ->
                        Just (assemble (T.pack out))
                    Right (ExitFailure _, _, _) -> Nothing
  where
    decodeHex =
        either (const Nothing) Just . B16.decode . TE.encodeUtf8

    assemble body =
        T.intercalate
            "\n"
            [ T.unlines turtlePrefixLines
            , TE.decodeUtf8 (metadataEntityTriples metadata)
            , body
            ]
