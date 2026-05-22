# Data Model — treasury-inspect dashboard (#239)

The slice introduces **no new on-chain or domain entities**. It reuses the existing `Amaru.Treasury.Inspect.*` types untouched and adds two small *carrier* entities for the HTTP / image surface.

## Reused (unchanged)

| Type | Module | Role in this slice |
|---|---|---|
| `InspectReport` | `Amaru.Treasury.Inspect.Types` | Full payload of `/v1/treasury-inspect?scope=<name>`. Same encoder (`Inspect.Render.encodeReport`) the CLI uses (SC-002). |
| `ScopeSection` | same | One scope's contribution: address, script hash, UTxOs, totals, pending swap orders. |
| `ScopeTotals`, `TreasuryUtxo`, `PendingSwapOrder`, `Outref`, `OtherAsset`, `ChainTip`, `DeploymentAnchor`, `ParsedSwapOrder` | same | Carried through. |
| `ScopeId` | `Amaru.Treasury.Scope` | Query-parameter validation; rejects anything outside the four enumerated scopes. |
| `Backend` / `Provider IO` | `Amaru.Treasury.Backend` (existing) | N2C wiring; reused as-is. |

## New entities (HTTP / image carriers only)

### `BuildIdentity`

The payload of `GET /v1/version` and the value rendered into the page footer (FR-022).

```haskell
data BuildIdentity = BuildIdentity
    { biGitCommit :: !Text
    -- ^ Short git sha of the amaru-treasury-tx commit used to build the image.
    , biMetadataSha256 :: !Text
    -- ^ Hex sha256 of the metadata.json baked into the image.
    , biMetadataSource :: !Text
    -- ^ Frozen upstream URL the metadata was pinned from, e.g.
    --   "github:pragma-org/amaru-treasury/<rev>".
    , biBuildTime :: !UTCTime
    -- ^ ISO-8601 timestamp the image derivation built at.
    , biRecentTxsCount :: !Int
    -- ^ Number of entries in the baked-in recent-txs manifest.
    }
```

JSON shape (key order alphabetical for byte-stable goldens):

```json
{
  "biBuildTime": "2026-05-22T20:45:00Z",
  "biGitCommit": "defc28fa",
  "biMetadataSha256": "8ea2c53b931efae432f5a7fc031b732147cc39b9b6159b4f6e1b22c8b78fa375",
  "biMetadataSource": "github:pragma-org/amaru-treasury/<rev>",
  "biRecentTxsCount": 10
}
```

Construction: all five fields are baked into the binary via `file-embed` of a derivation-generated JSON file (`nix/build-identity.nix`). The handler returns the embedded bytes verbatim. Read-only by construction.

### `RecentTxManifest` and `RecentTxEntry`

The payload of `GET /v1/recent-txs` (consumed by the dashboard footer). Sourced from `nix/recent-txs.nix` walking `transactions/2026/<scope>/<txid>/` at image-build time.

```haskell
data RecentTxManifest = RecentTxManifest
    { rtmEntries :: ![RecentTxEntry]
    -- ^ Newest first; at most 10.
    }

data RecentTxEntry = RecentTxEntry
    { rteScope :: !ScopeId
    , rteTxid :: !Text
    -- ^ 64-char hex; the directory name under transactions/2026/<scope>/.
    , rteSubmittedAt :: !UTCTime
    -- ^ mtime of tx.envelope.json (committed alongside the txid).
    , rteCardanoscanUrl :: !Text
    -- ^ "https://cardanoscan.io/transaction/<txid>"
    }
```

JSON shape:

```json
{
  "rtmEntries": [
    {
      "rteCardanoscanUrl": "https://cardanoscan.io/transaction/...",
      "rteScope": "network_compliance",
      "rteSubmittedAt": "2026-05-15T12:32:00Z",
      "rteTxid": "4e2642080c8d171aad05baed11b076de498b76acecc1c2412660048fae8aefa3"
    }
  ]
}
```

Construction:

1. `nix/recent-txs.nix` is a `runCommand` derivation with `transactions/2026/` as an input.
2. It walks the tree, collects `(scope, txid, mtime-of-tx.envelope.json)` triples, sorts by mtime descending, keeps the first ten.
3. Emits `recent-txs.json` into `$out/recent-txs.json`.
4. The image copies that file to `/etc/amaru-treasury/recent-txs.json`.
5. The handler reads it once at startup and serves the embedded JSON.

If `tx.envelope.json` is missing for any txid, the derivation **fails loudly** — no silent fallback. This honors FR-022b (the manifest is part of the image's identity).

### `ApiError`

A small wrapper for 400-class responses.

```haskell
data ApiError = ApiError
    { aeMessage :: !Text
    , aeField :: !(Maybe Text)
    -- ^ "scope" when the failure is a scope-validation failure.
    }
```

JSON:

```json
{ "aeField": "scope", "aeMessage": "Unknown scope 'foo'; expected one of: core_development, ops_and_use_cases, network_compliance, middleware." }
```

The handler returns 400 with this body when:

- `?scope=` is missing (FR-017 part 2)
- `?scope=` value is not one of the four registered scopes (FR-017 part 1)

500-class is the default servant behavior on internal errors; we do not customize it for this slice.

## Frontend domain types

The PureScript side mirrors the JSON shapes via hand-rolled decoders in `frontend/src/Api.purs`. Decoders are derived from the data-model.md shapes above; tests exercise round-trip against a recorded JSON fixture.

```purescript
type InspectReport =
  { irChainTip :: ChainTip
  , irDeployment :: DeploymentAnchor
  , irScopes :: Array ScopeSection
  }

type ScopeSection =
  { ssScope :: String
  , ssTreasuryAddress :: String
  , ssTreasuryScriptHash :: String
  , ssTreasuryUtxos :: Array TreasuryUtxo
  , ssTreasuryTotals :: ScopeTotals
  , ssPendingOrders :: Array PendingSwapOrder
  }
-- … etc.
```

No new on-chain or domain knowledge is required on the frontend — every field rendered is already present in the JSON.
