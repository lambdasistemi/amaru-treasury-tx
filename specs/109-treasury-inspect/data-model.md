# Phase 1 — Data Model

Entities from [spec.md](spec.md) §Key Entities mapped to concrete Haskell
record types. All records are `StrictData` (per the project flake), have
explicit field prefixes (project convention: `ir*`, `ss*`, …), and derive
`Eq`, `Show`. JSON shape: documented in
[contracts/treasury-inspect-schema.json](contracts/treasury-inspect-schema.json).

## InspectReport

The full report produced by one invocation of `treasury-inspect`.

```haskell
data InspectReport = InspectReport
  { irChainTip :: !ChainTip
  , irDeployment :: !DeploymentIdentifier
  , irScopes :: ![ScopeSection]
    -- ^ Stable order: as enumerated by `Scope.allScopes`
    --   (CoreDevelopment, OpsAndUseCases, NetworkCompliance,
    --    Middleware, Contingency), filtered by `--scope` if set.
  } deriving (Eq, Show)
```

## ChainTip

```haskell
data ChainTip = ChainTip
  { ctSlot :: !Word64
  , ctBlockHash :: !Text  -- 32-byte hex
  } deriving (Eq, Show)
```

## DeploymentIdentifier

The instance-NFT policy id pinned in metadata. Lives at
`TreasuryMetadata.tmScopeOwners` shape today (the UTxO holding the
scope-owners NFT). The "deployment identifier" surfaced to operators is
the policy id of that NFT — derivable from the metadata without a chain
round-trip.

```haskell
newtype DeploymentIdentifier = DeploymentIdentifier
  { unDeploymentIdentifier :: Text  -- bech32 or 28-byte hex policy id
  } deriving (Eq, Show)
```

*Open implementation note*: confirm in implement phase which exact field
in the existing metadata.json carries the instance NFT policy id and use
that. The plan assumes the value is already in metadata; if it is not,
the implement-phase task adds the derivation step.

## ScopeSection

One scope's contribution to the report.

```haskell
data ScopeSection = ScopeSection
  { ssScope :: !ScopeId  -- from Amaru.Treasury.Scope
  , ssTreasuryAddress :: !Text  -- bech32, copied from smAddress
  , ssTreasuryScriptHash :: !Text  -- 28-byte hex, copied from smTreasury.srHash
  , ssTreasuryUtxos :: ![TreasuryUtxo]
  , ssTreasuryTotals :: !ScopeTotals
  , ssPendingOrders :: ![PendingSwapOrder]
  } deriving (Eq, Show)
```

## ScopeTotals

Aggregates over `ssTreasuryUtxos`.

```haskell
data ScopeTotals = ScopeTotals
  { stLovelace :: !Integer
  , stUsdm :: !Integer
  , stOtherAssetsCount :: !Int
    -- ^ Number of distinct (policy, asset) pairs that are neither
    --   ADA nor USDM across all of the scope's treasury UTxOs.
    --   Surfaced so operators notice unexpected assets at a glance.
  } deriving (Eq, Show)
```

## TreasuryUtxo

A single UTxO at the scope's treasury script address.

```haskell
data TreasuryUtxo = TreasuryUtxo
  { tuOutref :: !Outref
  , tuLovelace :: !Integer
  , tuUsdm :: !Integer  -- 0 if absent
  , tuOtherAssets :: ![OtherAsset]
  , tuDatumHash :: !(Maybe Text)  -- 32-byte hex, if datum is hashed
  } deriving (Eq, Show)
```

## PendingSwapOrder

A SundaeSwap order UTxO attributed to this scope by destination
credential.

```haskell
data PendingSwapOrder = PendingSwapOrder
  { psoOutref :: !Outref
  , psoLovelaceIn :: !Integer  -- ADA committed to the swap
  , psoMinUsdmOut :: !Integer  -- chunk USDM lower bound
  , psoSundaeFeeLovelace :: !Integer  -- embedded protocol fee
  } deriving (Eq, Show)
```

## Outref

Project-wide outref shape — reuse the existing one if present, otherwise:

```haskell
data Outref = Outref
  { orTxId :: !Text  -- 32-byte hex
  , orIx :: !Word16
  } deriving (Eq, Show)
```

## OtherAsset

Catch-all for non-ADA / non-USDM assets at a treasury UTxO. The report
groups these so operators notice if something unexpected is held.

```haskell
data OtherAsset = OtherAsset
  { oaPolicy :: !Text  -- 28-byte hex
  , oaAssetName :: !Text  -- hex of bytes
  , oaQuantity :: !Integer
  } deriving (Eq, Show)
```

## Filtering rules

### Treasury UTxOs

UTxOs returned from `queryUTxOsAtH (smAddress scopeMeta)` for the scope
under consideration. No further filtering — every UTxO at the scope's
treasury address is part of the report.

### Pending swap orders

UTxOs returned from `queryUTxOsAtH sundaeSwapOrderAddress` are parsed
for their inline datum and filtered: keep iff the datum's destination
credential (`Constr 0` at index 3 → `Constr 0` → `Constr 1 [B
treasuryScriptHash]`) equals the scope's `srHash`. See `research.md` R1
for derivation.

The decoding helper lives in `lib/Amaru/Treasury/Inspect/SwapOrderDatum.hs`
and returns `Maybe ParsedSwapOrder`; UTxOs whose datum does not match the
SundaeSwap order shape are silently skipped (they are not Amaru-treasury
orders).

```haskell
data ParsedSwapOrder = ParsedSwapOrder
  { posDestinationTreasuryHash :: !ByteString
  , posLovelaceIn :: !Integer
  , posMinUsdmOut :: !Integer
  , posSundaeFeeLovelace :: !Integer
  } deriving (Eq, Show)

parseSwapOrderDatum :: Data -> Maybe ParsedSwapOrder
```

## Pure assembly function

The inspect logic itself is a pure function:

```haskell
buildInspectReport
  :: TreasuryMetadata
  -> ChainTip
  -> Map ScopeId [TreasuryUtxo]    -- pre-queried per scope
  -> [(Outref, ParsedSwapOrder)]   -- pre-queried at the order address
  -> Maybe ScopeId                 -- --scope filter
  -> InspectReport
```

This is the function exercised by the golden test; the I/O glue (the
two `queryUTxOsAtH` calls, the chain-tip query) lives in
`lib/Amaru/Treasury/Cli/TreasuryInspect.hs`.
