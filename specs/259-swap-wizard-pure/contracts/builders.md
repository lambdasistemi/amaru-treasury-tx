# Contract — `buildSwapIntent` and `buildSwapTx`

## `buildSwapIntent`

```haskell
buildSwapIntent
    :: GlobalOpts
    -> WizardOpts
    -> Backend
    -> Tracer IO WizardEvent
    -> IO (Either WizardFailure SwapIntent)
```

### Pre-conditions

- `GlobalOpts` was produced by the existing CLI parser (or a record literal honouring the same fields). The socket path it carries is informational only — the function does NOT open a new backend from it.
- `WizardOpts` likewise.
- `Backend` is a pre-opened handle (typically constructed by the caller via `withLocalNodeBackend` in the CLI shell, or held as a long-lived value in an HTTP server). `buildSwapIntent` MUST NOT open or close this handle; it MAY use it concurrently with other callers under the typeclass's documented thread-safety guarantees. If the handle is unusable at call time, the function returns `Left (ResolveEnv …)` — it does NOT throw a raw IOException out.
- The tracer is a valid `Tracer IO WizardEvent`; pass `nullTracer` to opt out.

### Post-conditions on `Right intent`

- `intent` is byte-identical to what the pre-refactor `runWizard` would have written to the configured output path for the same inputs.
- Encoding via the existing serialiser produces the canonical intent.json bytes.

### Post-conditions on `Left failure`

- `failure` matches one of the constructors enumerated in `data-model.md`.
- The host process is still running.
- The tracer has emitted the same `WizardEvent` sequence the pre-refactor wizard would have logged up to the abort site, but not the final "abort" text — the failure value carries that.

### Invariants (must hold across every call)

- **I1**: No `abortTr`, `die`, `exitWith` is reachable from the call graph.
- **I2**: Output bytes for `Right intent` are deterministic given identical inputs and identical chain state.
- **I3**: A `Left` value's `field`-bearing variants name a `FieldId` that maps 1:1 to a `WizardOpts` field.
- **I4**: Concurrent calls do not share log streams, output handles, or process exit state.

## `buildSwapTx`

```haskell
buildSwapTx
    :: ChainEnv
    -> SwapIntent
    -> Tracer IO BuildEvent
    -> IO (Either BuildFailure (CborHex, Report))
```

### Pre-conditions

- `ChainEnv` was constructed by the caller from a live chain snapshot (tip, params, era, slot-config). The caller decides how stale this snapshot may be.
- `SwapIntent` was either produced by `buildSwapIntent` (typical case) or read from a `intent.json` file via the existing deserialiser.

### Post-conditions on `Right (cbor, report)`

- `cbor` is byte-identical to what the pre-refactor `tx-build` would have written to the configured CBOR output path for the same inputs.
- `report` is byte-identical to what the pre-refactor `tx-build` would have written to the configured report.json output path.

### Post-conditions on `Left failure`

- `failure` matches one of the constructors enumerated in `data-model.md`.
- The host process is still running.
- The tracer has emitted the same `BuildEvent` sequence the pre-refactor builder would have logged up to the abort site.

### Invariants

- Same I1–I4 as `buildSwapIntent`, applied to `BuildFailure` and the tx-build call graph.

## Tracer contract

- `Tracer IO WizardEvent` (and `Tracer IO BuildEvent`) is INFORMATIONAL ONLY. A caller passing `nullTracer` MUST receive the same `Either` value as a caller passing a tracer.
- The CLI's existing `Tracer IO Text` is recovered by `contramap renderWizardEvent` over the typed tracer. No CLI-visible log line is dropped.

## Compatibility

- CLI flags, environment variables, and stderr-rendered error text are unchanged. Exit code semantics change per `spec.md` FR-008: non-zero on failure, mapped by failure family to sysexits codes (`Input*` → 64 `EX_USAGE`, `Resolve*` → 69 `EX_UNAVAILABLE`, `Internal*` → 70 `EX_SOFTWARE`). The new CLI wrapper is:

  ```haskell
  runWizard g o =
      withLocalNodeBackend (goNetworkMagic g) (fromMaybe "(unset)" (goSocketPath g)) $ \backend ->
          withLogHandle (wOptsLog o) $ \logH -> do
              let trText = Tracer (TIO.hPutStrLn logH)
                  tr     = contramap renderWizardEvent trText
              r <- buildSwapIntent g o backend tr
              writeOrDie r
  ```

- Existing call sites of `Build/Swap.hs` (if any non-CLI ones exist) are updated to the new entry point in this PR.

## Out-of-contract behaviour (explicitly not promised)

- Performance characteristics under concurrent invocation are not part of the contract beyond "no shared mutable state corrupts another call's result". Tuning chain-query concurrency is the follow-up vertical's concern.
- Streaming partial results (e.g., a `WeRegistryReady` event before the resolver finishes) is allowed but not required.
- The order of events emitted to the tracer is not part of the contract beyond "they appear before the function returns". Any reordering that does not lose information is permitted.
