# Exit-Code Contract — `reorganize-wizard`

Defines the exit code surfaces and the typed-error → exit-code
mapping. Mirrors the sibling
`Amaru.Treasury.Cli.RegistryInitWizard` exit-code convention.

## Exit-code matrix

| Exit code | Cause | Typed error (if any) | Stderr shape |
|---|---|---|---|
| **0** | `--help` printed, no work | — | optparse-applicative's standard help text on stdout (note: help goes to stdout, not stderr) |
| **1** | optparse-applicative parser failure | — | optparse-applicative's standard `Missing: ...` / `Invalid option` block |
| **2** | typed pre-flight error | `ReorganizeNonDevnetNetwork _` \| `ReorganizeOutputParentMissing _` \| `ReorganizeOutputExistsNoForce _` | `hPrint stderr e` → `<ConstructorName> <show-of-payload>` |
| **3** | runner-stub error | `ReorganizeTodoSliceC` | `hPrint stderr e` → `ReorganizeTodoSliceC` |

## Pre-flight ordering (FR-005)

`runReorganizeWizard g opts` executes the pre-flight tier as
follows, in order. Any failed step exits before the next runs;
no chain query, no socket open, no file write happens on any
exit-2 path.

```text
Step 1: --network devnet guard
  let n = resolveNetworkName g
  case n of
    Right "devnet"        -> pass step 1
    Right other           -> hPrint stderr (ReorganizeNonDevnetNetwork other)
                             exitWith (ExitFailure 2)
    Left _                -> hPrint stderr (ReorganizeNonDevnetNetwork "<unresolved>")
                             exitWith (ExitFailure 2)
                             -- (treats unresolvable network magics as non-devnet)

Step 2: --out parent directory pre-flight
  let out = cfOut (rwoCommon opts)
  let force = cfForce (rwoCommon opts)
  r <- validateOutPath out force
  case r of
    Right () -> pass step 2
    Left e   -> hPrint stderr e
                exitWith (ExitFailure 2)

Step 3: stub runner body
  hPrint stderr ReorganizeTodoSliceC
  exitWith (ExitFailure 3)
```

**Ordering rationale**:

- Step 1 first (string compare, no I/O) — cheapest check.
- Step 2 second (one `doesDirectoryExist` syscall) — cheap I/O.
- Step 3 third (no I/O on the stub path).

In practice the user only ever sees one exit-2 surface per
invocation. Reordering 1 ↔ 2 would not change which exit code
fires for any individual flag-set; both error tiers are exit
code 2, just with different typed errors. The contract pins the
order for test predictability.

## Test interception

`runReorganizeWizard` itself is `IO ()` that calls `exitWith` on
the error path. To make the runner testable without subprocess
spawning, the slice executor SHIPS a sibling helper:

```haskell
-- | Like 'runReorganizeWizard' but returns the typed error
-- instead of exiting.  Used by 'ReorganizeWizardParserSpec'.
runReorganizeWizardEither
    :: GlobalOpts
    -> ReorganizeWizardOpts
    -> IO (Either ReorganizeError ())
```

`runReorganizeWizard` is then a thin shim:

```haskell
runReorganizeWizard :: GlobalOpts -> ReorganizeWizardOpts -> IO ()
runReorganizeWizard g opts = do
    r <- runReorganizeWizardEither g opts
    case r of
        Right ()          -> pure ()
        Left e            -> do
            hPrint stderr e
            exitWith (ExitFailure (exitCodeFor e))

exitCodeFor :: ReorganizeError -> Int
exitCodeFor = \case
    ReorganizeNonDevnetNetwork{}     -> 2
    ReorganizeOutputParentMissing{}  -> 2
    ReorganizeOutputExistsNoForce{}  -> 2
    ReorganizeTodoSliceC             -> 3
```

The test spec calls `runReorganizeWizardEither` directly, asserts
the `Either`, and does not need to intercept any `ExitException`.

## Sibling precedent

This contract mirrors the pre-flight + runner-stub pattern in:

- `Amaru.Treasury.Cli.RegistryInitWizard.guardOut` (the pre-flight
  shim) — lines 543–549 of the file.
- `Amaru.Treasury.Cli.RegistryInitWizard.validateOutPath` — lines
  496–507.
- `Amaru.Treasury.Cli.RegistryInitWizard.runSeedSplitBootstrap`'s
  devnet check — lines 860–865.

The reorganize wizard's `validateOutPath` is essentially the
same function with a different `ReorganizeError` type. The
slice executor MAY copy `validateOutPath` body-for-body
(swapping the error type) or extract a shared helper into
`Amaru.Treasury.Cli.Common` (would expand the owned-files
scope; **default is copy**).

## What this contract does NOT cover

- The runner-body exit codes for #187's real runner (chain query
  failures, missing UTxOs, validity-bound sampling failures,
  etc.) — those will extend `ReorganizeError` and grow the
  exit-code matrix at that ticket.
- Devnet-only network magics other than 42 — `resolveNetworkName`
  returns `Right "devnet"` iff the resolved name string is
  literally `"devnet"`. A custom magic that happens to map to
  devnet would still surface `Left _` from
  `resolveNetworkName` and trigger
  `ReorganizeNonDevnetNetwork "<unresolved>"`. This is a
  parent-epic carry-forward: every wizard treats unresolved
  magics as non-devnet for safety.
