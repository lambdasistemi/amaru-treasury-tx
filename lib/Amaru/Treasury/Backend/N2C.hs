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
    , withLocalNodeClient
    , probeNetworkMagic
    , probeResultAccepted
    , findSocketMagic
    , knownNetworkMagics
    , superviseConnection
    , reconnectInitialDelay
    , reconnectMaxDelay
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
    ( withAsync
    )
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , displayException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (void)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Clock (getMonotonicTime)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Submitter
    ( Submitter
    )
import Ouroboros.Consensus.Ledger.Query
    ( Query (GetChainPoint)
    )

import Amaru.Treasury.Backend (Backend, Provider)
import Amaru.Treasury.Trace
    ( Severity
    , filterSeverity
    )
import Amaru.Treasury.Trace.Provider
    ( stderrTracer
    , tracedProvider
    , tracedSubmitter
    )

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
    -> Severity
    -- ^ minimum severity for provider tracing
    -> (Backend -> IO a)
    -- ^ action that consumes the 'Backend'
    -> IO a
withLocalNodeBackend magic socketPath minimumSeverity action = do
    lsq <- newLSQChannel 4
    ltxs <- newLTxSChannel 1
    let tracer = filterSeverity minimumSeverity stderrTracer
        backend = tracedProvider tracer (mkN2CProvider lsq)
        connect =
            superviseConnection
                getMonotonicTime
                threadDelay
                reportConnection
                (runNodeClient magic socketPath lsq ltxs)
    withAsync connect $ \_ -> action backend

{- | Run an 'IO' action with local-node-backed query and submission
channels. This is the command-runner variant used by DevNet bootstrap
commands that need to query protocol parameters, build from live UTxOs,
and submit transactions in one N2C session.
-}
withLocalNodeClient
    :: NetworkMagic
    -- ^ network magic (mainnet, preprod, preview, devnet)
    -> FilePath
    -- ^ path to the cardano-node socket
    -> Severity
    -- ^ minimum severity for provider and submitter tracing
    -> (Provider IO -> Submitter IO -> IO a)
    -- ^ action that consumes provider and submitter
    -> IO a
withLocalNodeClient magic socketPath minimumSeverity action = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    let tracer = filterSeverity minimumSeverity stderrTracer
        provider = tracedProvider tracer (mkN2CProvider lsq)
        submitter = tracedSubmitter tracer (mkN2CSubmitter ltxs)
        connect =
            superviseConnection
                getMonotonicTime
                threadDelay
                reportConnection
                (runNodeClient magic socketPath lsq ltxs)
    withAsync connect $ \_ -> action provider submitter

-- | First reconnect delay, in microseconds.
reconnectInitialDelay :: Int
reconnectInitialDelay = 250_000

-- | Longest reconnect delay, in microseconds.
reconnectMaxDelay :: Int
reconnectMaxDelay = 30_000_000

{- | A connection that lived at least this many seconds
was healthy: the next reconnect starts from
'reconnectInitialDelay' again.
-}
reconnectHealthySeconds :: Double
reconnectHealthySeconds = 60

{- | Keep an N2C connection alive for as long as the caller
runs. Whenever the connection ends — the node restarted,
the socket vanished, or the LSQ channel timed a query out
and invalidated the session — it is started again on the
same channels after an exponential backoff.

The channels outlive any one connection: callers pending
on a lost connection fail with a connection-lost error,
later callers are served by the next one. Without this,
the first connection loss strands every later query on a
queue that nothing reads (#508).

Asynchronous exceptions end the loop, so cancelling the
owning 'withAsync' still tears the connection down.
-}
superviseConnection
    :: IO Double
    -- ^ monotonic clock, in seconds
    -> (Int -> IO ())
    -- ^ sleep, in microseconds
    -> (String -> IO ())
    -- ^ report why a connection ended
    -> IO (Either SomeException ())
    -- ^ run one connection until it ends
    -> IO a
superviseConnection clock sleep report connectOnce =
    go reconnectInitialDelay
  where
    go delay = do
        started <- clock
        outcome <- try connectOnce
        ended <- clock
        reason <- case outcome of
            Left e -> synchronousOnly e
            Right (Left e) -> synchronousOnly e
            Right (Right ()) -> pure "closed"
        let wait
                | ended - started >= reconnectHealthySeconds =
                    reconnectInitialDelay
                | otherwise = delay
        report $
            "n2c connection ended ("
                <> reason
                <> "); reconnecting in "
                <> show (wait `div` 1_000)
                <> " ms"
        sleep wait
        go $ min reconnectMaxDelay (2 * wait)
    synchronousOnly e = case fromException e of
        Just (_ :: SomeAsyncException) -> throwIO e
        Nothing -> pure $ displayException e

-- | Report a supervised connection's end on stderr.
reportConnection :: String -> IO ()
reportConnection = hPutStrLn stderr . ("amaru-treasury: " <>)

{- | Probe whether a Unix socket accepts the given
'NetworkMagic' on the N2C handshake. Returns 'True' if
the handshake completes and LocalStateQuery can answer a
cheap chain-point query. Returns 'False' if the query
does not answer within the timeout or any exception is
raised (treated as "socket unreachable / wrong
network").

The timeout is short on purpose: a local-Unix N2C
handshake and LSQ chain-point query complete in tens of
milliseconds; anything slower is a sign that the socket
is unreachable, still replaying, or the magic is wrong.
After the probe we abandon the channels and let the
caller open a fresh connection if it wants to.
-}
probeNetworkMagic
    :: NetworkMagic
    -> FilePath
    -> IO Bool
probeNetworkMagic magic socketPath = do
    lsq <- newLSQChannel 1
    ltxs <- newLTxSChannel 1
    r <-
        timeout 1_500_000
            $ try @SomeException
            $ withAsync
                (runNodeClient magic socketPath lsq ltxs)
            $ \_ -> void (queryLSQ lsq GetChainPoint)
    pure (probeResultAccepted r)

-- | Interpret the bounded LSQ probe result.
probeResultAccepted :: Maybe (Either e a) -> Bool
probeResultAccepted (Just (Right _)) = True
probeResultAccepted _ = False

{- | Curated allow-list of network names ↔ magics. Mirrors
the case in 'app/amaru-treasury-tx/Main.hs' that maps
'tiNetwork' to a 'NetworkMagic'. @devnet@ is a
local-only test network used by the opt-in smoke harness.
-}
knownNetworkMagics :: [(Text, NetworkMagic)]
knownNetworkMagics =
    [ ("mainnet", NetworkMagic 764_824_073)
    , ("preprod", NetworkMagic 1)
    , ("preview", NetworkMagic 2)
    , ("devnet", NetworkMagic 42)
    ]

{- | Identify the socket's actual network magic by
walking the candidates that are NOT the intent's
declared network. The probe function is injected so this
helper is unit-testable without a real Unix socket
('test/unit/Amaru/Treasury/BuildSpec.hs'). The
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
