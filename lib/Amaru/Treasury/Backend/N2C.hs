{- |
Module      : Amaru.Treasury.Backend.N2C
Description : Local-node Backend constructor (N2C)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The default 'Backend' implementation: connects to a
local @cardano-node@ via the Node-to-Client (N2C)
LocalStateQuery mini-protocol and exposes the resulting
'Provider' to the rest of the CLI.

This is the only impure module in
@Amaru.Treasury.*@ at this stage; everything else
(parsers, redeemers, builders) is pure and consumes
'Backend' through 'Cardano.Node.Client.Provider'.
-}
module Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    ) where

import Control.Concurrent.Async
    ( withAsync
    )
import Control.Exception (throwIO)
import Ouroboros.Network.Magic (NetworkMagic)

import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)

import Amaru.Treasury.Backend (Backend)

{- | Run an 'IO' action with a local-node-backed
'Backend'. Spawns a background thread that drives the
N2C mux and tears it down when the action returns.

The LSQ queue is sized for the CLI's modest needs (one
inflight query at a time). Tx submission is not used
at this stage — we still wire the LTxS channel because
'runNodeClient' multiplexes both protocols on the same
session, but we never push to the LTxS queue.
-}
withLocalNodeBackend
    :: NetworkMagic
    -- ^ network magic (mainnet, preprod, preview)
    -> FilePath
    -- ^ path to the cardano-node socket
    -> (Backend -> IO a)
    -- ^ action that consumes the 'Backend'
    -> IO a
withLocalNodeBackend magic socketPath action = do
    lsq <- newLSQChannel 4
    ltxs <- newLTxSChannel 1
    let backend = mkN2CProvider lsq
        connect = do
            r <- runNodeClient magic socketPath lsq ltxs
            case r of
                Right () -> pure ()
                Left e -> throwIO e
    withAsync connect $ \_ -> action backend
