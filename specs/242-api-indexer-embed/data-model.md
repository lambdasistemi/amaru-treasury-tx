# Data Model: in-process indexer embed inside `amaru-treasury-tx-api`

**Branch**: `feat/242-api-indexer-embed` | **Date**: 2026-05-24
**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Types and signatures introduced or modified by this slice.
Live signatures are draft; the final shape lands in the slice
commits and may differ in superficial detail (named-field vs
positional, `Word64` vs `SlotNo` typedef choice). The
contracts below are load-bearing.

## New types

### `Amaru.Treasury.Api.Indexer` (new module)

```haskell
-- | Static configuration captured from CLI flags and
-- environment.
data IndexerConfig = IndexerConfig
  { icDbPath          :: !FilePath
    -- ^ RocksDB directory. Created if missing.
  , icSocketPath      :: !FilePath
    -- ^ Node N2C socket the chain-sync follower connects to.
    -- The same socket as the API container's existing
    -- 'Backend' uses for nowTip + submission; we open a second
    -- N2C session here for chain-sync.
  , icNetworkMagic    :: !NetworkMagic
  , icStartSlot       :: !SlotNo
    -- ^ Cold-boot starting slot (ignored when the DB has a
    -- prior cursor; see Indexer.startsFromExistingState).
  , icLagThresholdSlots :: !Word64
    -- ^ Drift threshold: when (tip_slot - processed_slot) >
    -- this value, the readiness predicate flips to NotReady
    -- and every handler returns HTTP 503.
  }
  deriving (Eq, Show)

-- | Live readiness snapshot updated by the follower thread.
data Readiness = Readiness
  { rProcessedSlot :: !SlotNo
  , rTipSlot       :: !SlotNo
  , rLagSlots      :: !Word64
  , rUpstreamUp    :: !Bool
  , rUpdatedAt     :: !UTCTime
  }
  deriving (Eq, Show)

-- | Three-state readiness verdict the handlers consume.
data ReadyState
  = Pending      -- ^ Cold boot, follower not yet up to threshold.
  | Ready        -- ^ Within lagThreshold of tip; serve normally.
  | Lagging !Word64 !Word64
                 -- ^ Lag-slots, threshold-slots. Serve 503.
  deriving (Eq, Show)

-- | The opaque handle the API container threads through Handlers.
data ApiIndexer = ApiIndexer
  { aiHandle      :: !IndexerHandle
    -- ^ Underlying utxo-indexer-lib handle, shared between
    -- follower (writes) and handlers (reads).
  , aiReadiness   :: !(TVar Readiness)
    -- ^ Updated by the follower after each batch apply.
  , aiFollower    :: !(Async ())
    -- ^ The follower thread; main thread should 'link' it so
    -- exceptions propagate.
  , aiConfig      :: !IndexerConfig
  }

-- | Bring up the indexer (open RocksDB, start follower,
-- initialise readiness). Blocks until the follower has
-- reported at least one tip observation, then returns. Does
-- NOT block until the indexer is caught up — see 'waitReady'
-- for that. Resource is bracketed: on exit the follower is
-- cancelled and RocksDB is closed.
withApiIndexer
  :: Tracer IO N2CEvent
  -> IndexerConfig
  -> (ApiIndexer -> IO a)
  -> IO a

-- | Block until 'ReadyState' is 'Ready'. Called at boot by
-- Main.hs before binding warp; should NOT be called from
-- per-request handler code (use 'checkReady' there).
waitReady :: ApiIndexer -> IO ()

-- | Per-request readiness check. Returns the current verdict
-- without blocking.
checkReady :: ApiIndexer -> IO ReadyState

-- | Per-request UTxO scan at an address. Microsecond-class
-- when the address is in RocksDB; empty list when not.
snapshotAt :: ApiIndexer -> Addr -> IO [(TxIn, TxOut ConwayEra)]
```

### `Amaru.Treasury.Api.Server` (edited)

`Handlers` is reshaped so the `hInspect` field embeds the
`ApiIndexer`-bound closure. The `mkApplication` signature is
unchanged.

```haskell
-- Existing record, no field renames or removals.
-- A small middleware (or helper) layered above all handlers
-- short-circuits with HTTP 503 when 'checkReady' returns
-- 'Lagging'.
data Handlers = Handlers
  { hInspect    :: ScopeId -> Servant.Handler InspectReport
  , hRecentTxs  :: Servant.Handler RecentTxManifest
  , hVersion    :: Servant.Handler BuildIdentity
  }

-- New helper used by Main.hs to build the inspect closure.
-- See research.md §3 for the rationale of capturing
-- ApiIndexer + the existing Provider IO + the static metadata
-- bundle.
mkInspectHandler
  :: ApiIndexer
  -> Provider IO          -- existing N2C session; used for nowTip
  -> TreasuryMetadata
  -> DeploymentAnchor
  -> Addr                 -- swap-order address
  -> ScopeId
  -> Servant.Handler InspectReport
```

### `Amaru.Treasury.Constants` (edited)

```haskell
-- | Mainnet cold-boot starting slot for the embedded
-- 'utxo-indexer-lib' follower. Picked a few epochs before the
-- earliest treasury deployment so the cold-sync skips
-- irrelevant pre-deployment history. Operator can override
-- via --indexer-start-slot.
mainnetIndexerStartSlot :: SlotNo
mainnetIndexerStartSlot = SlotNo 149_000_000
```

### CLI flag additions in `app/amaru-treasury-tx-api/Main.hs`

```haskell
-- All optional except --indexer-db; defaults match research.md.
indexerOptsP :: Parser IndexerCliOpts
indexerOptsP = IndexerCliOpts
  <$> strOption
        ( long "indexer-db"
       <> metavar "PATH"
       <> help "RocksDB directory for the embedded indexer." )
  <*> option auto
        ( long "indexer-lag-threshold-slots"
       <> metavar "SLOTS"
       <> value 60
       <> help "Lag-slots above which the service returns HTTP 503. \
              \Default 60 (~60s on mainnet)." )
  <*> optional ( option auto
        ( long "indexer-start-slot"
       <> metavar "SLOT"
       <> help "Override the mainnet cold-boot starting slot. \
              \Default: Amaru.Treasury.Constants.mainnetIndexerStartSlot." ))
```

## Paired upstream types (in `cardano-node-clients`)

These ship in the upstream PR before the downstream Slice 1.

### `Cardano.Node.Client.UTxOIndexer.Follower` (new module)

```haskell
data ChainSyncConfig = ChainSyncConfig
  { csSocketPath   :: !FilePath
  , csNetworkMagic :: !NetworkMagic
  , csStartingSlot :: !SlotNo
    -- ^ Used only when the IndexerHandle has no prior cursor;
    -- otherwise getResumePoints wins.
  }

data FollowerHandle = FollowerHandle
  { fhReadiness :: !(STM Readiness)
  , fhAsync     :: !(Async ())
  }

data Readiness = Readiness
  { rProcessedSlot :: !SlotNo
  , rTipSlot       :: !SlotNo
  , rUpstreamUp    :: !Bool
  , rUpdatedAt     :: !UTCTime
  }

withChainSyncFollower
  :: Tracer IO N2CEvent
  -> ChainSyncConfig
  -> IndexerHandle
  -> (FollowerHandle -> IO a)
  -> IO a
```

### `Cardano.Node.Client.UTxOIndexer.Daemon` (edited)

`runDaemon` is re-implemented atop `withChainSyncFollower`:

```haskell
runDaemon :: Tracer IO N2CEvent -> DaemonConfig -> IO ()
runDaemon tracer cfg =
  withRocksDBIndexer (dcDbPath cfg) $ \handle ->
    withChainSyncFollower tracer (toChainSyncCfg cfg) handle $ \fh ->
      withNdjsonServer (dcServerCfg cfg) handle fh $
        forever (threadDelay maxBound)
```

No public-facing change to `runDaemon`'s type or behaviour;
the daemon binary's e2e tests stay green unchanged.

## Removed types and values

Deleted in Slice 2 (`app/amaru-treasury-tx-api/Main.hs`):

```haskell
type InspectCache = IORef (Map ScopeId (UTCTime, InspectReport))

refreshIntervalSeconds :: Int
refreshIntervalSeconds = 30

cachedInspect
  :: InspectCache
  -> Provider IO
  -> TreasuryMetadata
  -> DeploymentAnchor
  -> Addr
  -> ScopeId
  -> Servant.Handler InspectReport

refreshAll
  :: Provider IO
  -> TreasuryMetadata
  -> DeploymentAnchor
  -> Addr
  -> InspectCache
  -> IO ()

refreshLoop
  :: Provider IO
  -> TreasuryMetadata
  -> DeploymentAnchor
  -> Addr
  -> InspectCache
  -> IO Void

-- Plus the inline `cache <- newIORef Map.empty` boot wiring
-- and the `withAsync (refreshLoop …)` block.
```

After Slice 2, `git grep IORef app/amaru-treasury-tx-api/`
returns nothing.
