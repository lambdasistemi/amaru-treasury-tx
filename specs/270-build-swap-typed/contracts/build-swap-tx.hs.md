# Contract — `buildSwapTx` Haskell surface

**Module**: `Amaru.Treasury.Wizard.Swap`
**Stability**: load-bearing public API; signature change requires a spec update.

```haskell
buildSwapTx
  :: GlobalOpts
  -> Backend
  -> SwapIntent
  -> Tracer IO BuildEvent
  -> ExceptT BuildFailure IO (CborHex, Report)
```

## Behavioural contract

| Property                                                                                                                              | Test                                                                                                                                              |
|---------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| Pure-Either: every failure path resolves to `Left <BuildFailure ctor>`. No `exitWith`, `error`, `throwIO`, `abortTr` reachable.        | `BuildSwapSpec` — static grep + per-variant harness. SC-003.                                                                                       |
| Backend-injected: function does NOT open or close `Backend`. Same instance used across many calls without rebuild.                     | `BuildSwapSpec` reuses one fake `Backend` for the whole spec; lifecycle is per-suite, not per-call.                                                |
| Tracer-informational: `nullTracer` vs real tracer produces identical `Right` value AND identical step ordering.                        | `BuildSwapSpec.prop_tracerInformational`. FR-004.                                                                                                  |
| Golden-stable: for every input in the existing swap CLI corpus, the produced `(CborHex, Report)` matches the v0.2.15.0 baseline byte-for-byte. | `BuildSwapGoldenSpec` — re-runs the fixture set through `buildSwapTx` and compares against checked-in `*.cbor` / `report.json` fixtures. SC-001.   |

## Companion symbols

```haskell
-- ExitCode mapping for CLI wrappers — keeps sysexits 64/69/70.
sysexitsForBuild :: BuildFailure -> ExitCode
```

## CLI rewire contract

The CLI wrapper that previously called `Build.Swap.runSwap` now reads:

```haskell
runWizardTx :: GlobalOpts -> WizardOpts -> Tracer IO Text -> IO ExitCode
runWizardTx opts wopts logTracer = withLocalNodeBackend opts $ \backend -> do
  buildEvTracer <- mkBuildEventTracer logTracer
  result <- runExceptT $ do
    intent <- buildSwapIntent opts wopts backend wizardEvTracer
    buildSwapTx opts backend intent buildEvTracer
  case result of
    Left (Left wf) -> reportAndExit (sysexitsFor wf)         (renderWizardFailure wf)
    Left (Right bf) -> reportAndExit (sysexitsForBuild bf)   (renderBuildFailure bf)
    Right (cborHex, report) -> writeOutputs cborHex report   *> pure ExitSuccess
```

(The actual code threads `Either` through `ExceptT` cleanly; the snippet above is illustrative of the failure-arm dispatch.)
