# Plan

## Design Choice

Use the narrow `indexerProvider` fix from the issue body:
`withLocalNodeBackend` and `withLocalNodeClient` continue returning
traced N2C providers, and `indexerProvider` stops applying
`tracedProvider` to the entire record. Instead, `indexerProvider`
applies the provider-trace labels only to the UTxO closures it creates
itself.

This preserves CLI/devnet coverage because those paths still receive
the N2C-level wrapper. It avoids API duplication because pass-through
fields are no longer rewrapped outside the already-traced provider.

## Implementation Notes

- `lib/Amaru/Treasury/Backend/N2C.hs` stays traced at construction
  sites.
- `lib/Amaru/Treasury/Api/Server.hs` owns the API-specific shape:
  direct `queryUTxOs` and `queryUTxOByTxIn` use traced indexer actions;
  acquired-handle `backendQueryUTxOs`, `backendQueryUTxOsAt`, and
  `backendQueryUTxOByTxIn` use traced indexer actions; pass-through
  methods delegate to the handle/provider supplied by the already-traced
  real provider.
- `lib/Amaru/Treasury/Trace/Provider.hs` should only change if the
  driver finds a small reusable helper materially clearer than local
  `traced tr Info` calls in `Server.hs`.
- `test/unit/Amaru/Treasury/Trace/ProviderSpec.hs` should be updated to
  prove both construction requirements: N2C constructors wrap with
  `tracedProvider`, and `indexerProvider` traces only its indexer
  override labels instead of wrapping the whole record.

## Verification

Local gate:

```bash
./gate.sh
```

Focused proof while implementing:

```bash
nix develop --quiet -c just unit "/Trace.Provider/"
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
```

Live/devnet proof should be attempted after the code slice. If a local
node/devnet setup is not available in this worktree, record the reason
and provide the code-path proof plus the exact command/log pattern for
operator follow-up.

## Slices

### Slice 1: Remove API double wrap without losing override traces

Driver updates `Server.hs` and focused provider-trace tests. Navigator
reviews RED and GREEN handoffs. The commit must be bisect-safe and pass
the focused unit, format, and hlint checks before handoff.

### Slice 2: Verification, PR metadata, and readiness

Orchestrator runs the full local gate, attempts live/devnet evidence,
updates the PR body with the final evidence, drops `gate.sh`, waits for
GitHub Actions, and only then logs `COMPLETE`.
