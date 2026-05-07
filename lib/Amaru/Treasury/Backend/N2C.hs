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
    , probeNetworkMagic
    , findSocketMagic
    , knownNetworkMagics
    ) where

import Control.Concurrent.Async
    ( withAsync
    )
import Control.Exception (SomeException, throwIO, try)
import Data.Text (Text)
import Data.Word (Word32)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Timeout (timeout)

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

{- | Probe whether a Unix socket accepts the given
'NetworkMagic' on the N2C handshake. Returns 'True' if
the handshake completes (i.e. the socket's network
matches), 'False' if 'runNodeClient' returns a Left
within the timeout, and 'False' on any other exception
(treated as "socket unreachable / wrong network").

The timeout is short on purpose: a local-Unix N2C
handshake completes in tens of milliseconds; anything
slower is a sign that the socket is unreachable or the
magic is wrong. After the probe we abandon the channels
and let the caller open a fresh connection if it wants
to.
-}
probeNetworkMagic
    :: NetworkMagic
    -> FilePath
    -> IO Bool
probeNetworkMagic magic socketPath = do
    lsq <- newLSQChannel 1
    ltxs <- newLTxSChannel 1
    r <-
        timeout 1_500_000 $
            try (runNodeClient magic socketPath lsq ltxs)
    pure $ case r of
        Nothing -> True
        -- timeout fired => handshake completed, conn open
        Just (Right (Right ())) -> True
        -- runNodeClient returned cleanly (rare)
        Just (Right (Left _)) -> False
        -- handshake refused
        Just (Left (_ :: SomeException)) -> False

{- | Curated allow-list of network names ↔ magics. Mirrors
the case in 'app/amaru-treasury-tx/Main.hs' that maps
'tiNetwork' to a 'NetworkMagic'.
-}
knownNetworkMagics :: [(Text, NetworkMagic)]
knownNetworkMagics =
    [ ("mainnet", NetworkMagic 764_824_073)
    , ("preprod", NetworkMagic 1)
    , ("preview", NetworkMagic 2)
    ]

{- | Identify the socket's actual network magic by
walking the candidates that are NOT the intent's
declared network. The probe function is injected so this
helper is unit-testable without a real Unix socket
('test/unit/Amaru/Treasury/TreasuryBuildSpec.hs'). The
production caller wires
'flip probeNetworkMagic socket' as the probe.

Returns @0@ if no candidate succeeds — sentinel for
"socket unreachable / unknown network".
-}
findSocketMagic
    :: (Monad m)
    => (NetworkMagic -> m Bool)
    -- ^ probe (returns 'True' when the magic is accepted)
    -> Text
    -- ^ intent's declared network name
    -> m Word32
findSocketMagic probe intentNet = go probesFor
  where
    probesFor =
        filter
            (\(n, _) -> n /= intentNet)
            knownNetworkMagics
    go [] = pure 0
    go ((_, m) : rest) = do
        ok <- probe m
        if ok
            then pure (unNetworkMagic m)
            else go rest
