# Implementation Plan: Provider Boundary Tracing

## Context

Epic #451 introduces contravariant tracer-based observability across
the build/verify provider boundary. #452 is already merged and provides
`Severity`, `filterSeverity`, and `traced`. #453 is still open, so this
ticket must use always-on stderr rendering.

The upstream `Provider IO` interface has more methods than the issue's
examples. The current surface includes direct queries, acquired-handle
queries, slot conversion, `queryUpperBoundSlot`, and transaction
evaluation. Transaction submission is on `Submitter IO`, not
`Provider IO`, but the brief explicitly names `submitTx`, so this plan
includes a submitter wrapper.

## Design

Add a small module, `Amaru.Treasury.Trace.Provider`, exporting:

- `stderrTracer :: Tracer IO (Severity, Text)`
- `renderTraceLine :: Severity -> Text -> Text`
- `tracedProvider :: Tracer IO (Severity, Text) -> Provider IO -> Provider IO`
- `tracedQueryHandle :: Tracer IO (Severity, Text) -> QueryHandle IO -> QueryHandle IO`
- `tracedSubmitter :: Tracer IO (Severity, Text) -> Submitter IO -> Submitter IO`

Labels should be stable and greppable, using the provider method names,
for example `provider.queryProtocolParams`,
`provider.withAcquired`, `provider.handle.evaluateTxH`, and
`submitter.submitTx`.

The `withAcquired` wrapper traces the outer acquisition callback and
passes a traced `QueryHandle` into the callback. This proves both the
session boundary and per-handle operations.

Apply `tracedProvider stderrTracer` and `tracedSubmitter stderrTracer`
in `Amaru.Treasury.Backend.N2C` at the construction boundary:

- `withLocalNodeBackend`
- `withLocalNodeClient`

Preserve API indexer adapter behavior by tracing the synthetic provider
returned by `Amaru.Treasury.Api.Server.indexerProvider` or by applying
the wrapper at the build/inspect provider construction points.

## Slices

### Slice 1: reusable wrappers and unit proof

Owned files:

- `amaru-treasury-tx.cabal`
- `lib/Amaru/Treasury/Trace/Provider.hs`
- `test/unit/Amaru/Treasury/Trace/ProviderSpec.hs`

Implement the wrappers and focused unit tests against fake providers,
query handles, and submitters. The tests should call every wrapped
method and assert trace labels for start and terminal events. Use dummy
or throwing implementations where constructing successful ledger values
would be too expensive; failure paths are acceptable proof because
`traced` emits start and failed terminal events.

Focused command:

```bash
nix develop --quiet -c cabal test unit-tests -O0 --test-options "--match /Trace.Provider/"
```

Commit:

```text
feat(tracing): add provider boundary tracing wrappers

Tasks: T454-S1
```

### Slice 2: construction-site wiring and final proof

Owned files:

- `lib/Amaru/Treasury/Backend/N2C.hs`
- `lib/Amaru/Treasury/Api/Server.hs`
- `test/unit/Amaru/Treasury/Trace/ProviderSpec.hs`

Wire the wrappers at provider construction sites. Keep
`ChainContext.hs`, `Registry/Verify.hs`, wizard event modules, and
verbosity/config files untouched.

Focused command:

```bash
nix develop --quiet -c cabal test unit-tests -O0 --test-options "--match /Trace.Provider/"
./gate.sh
```

Commit:

```text
feat(tracing): wire provider tracing at construction sites

Tasks: T454-S2
```

## Risks

- The provider dependency may add methods over time. The wrapper should
  use an explicit record construction so compilation fails if a new
  field is added.
- API indexer provider wrapping must avoid losing indexer-backed UTxO
  behavior. Tests should exercise synthetic provider wrapping directly,
  not rely on a live node.
- The local commit hook may still hit the known `cuddle` SRP failure;
  workers may commit with `--no-verify` after running `./gate.sh`.
