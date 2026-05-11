# Research: Normalize tx-build Builder Errors

Phase 0 decisions for issue #79.

## D1. Project-owned diagnostic type

**Decision**: introduce a project-owned diagnostic type for build failures and render that type for CLI/report output.

**Rationale**: upstream `BuildError` and `BalanceError` are useful implementation detail, but their `Show` output is not a user contract. A local diagnostic type lets the project define stable codes and wording while still carrying useful upstream data.

**Alternatives considered**:

- Render `show (BuildError ())` directly. Rejected: this is the current defect.
- Pattern-match only in `app/Main.hs`. Rejected: the raw `userError` strings are already produced in `TreasuryBuild`; normalizing later means parsing exceptions or losing structure.
- Change upstream `cardano-node-clients`. Rejected for this issue: the project can define a better user contract without waiting on dependency changes.

## D2. Error flow with ExceptT

**Decision**: use an inner action-level `ExceptT ActionBuildError IO` in IO build runners when it materially reduces nested `case` and repeated `throwIO . userError` code. At dispatcher boundaries, lift that nested error into the public `TreasuryBuildError` with `withExceptT`, so the outer diagnostic carries the action while lower-level code stays action-agnostic. Expose a normal `IO` runner for compatibility, but let `runTxBuild` consume an `Either`-returning entry point where practical.

**Rationale**: the runners are IO boundaries already. `ExceptT` is appropriate for expected build failures: missing UTxOs, upstream `BuildError`, fee alignment failure, and validation failure. `withExceptT` is the right tool for nesting the action-local error into the public diagnostic without hand-written `Either` plumbing at every call site. It keeps the pure `TxBuild q e a` builders unchanged while making error exits explicit and testable.

**Alternatives considered**:

- Keep throwing `IOException` via `userError`. Rejected: it hides typed semantics and forces CLI/report code to work from `SomeException`.
- Return `Either` manually from every helper. Plausible, but it tends to produce the same nested `case` syntax the user asked to clean up.
- Use `MonadThrow` exceptions only. Rejected for expected build failures; exceptions remain useful at the outer compatibility boundary, not as the primary error model.

## D3. Structured exception context with mapException

**Decision**: model expected build exceptions as structured values, like trace events. Use the `mapException` pattern at context boundaries to enrich or translate lower-level exceptions; for `IO` actions, apply the same typed mapping through `try`/`catch` because base `mapException` maps exceptions in pure expressions.

`mapException` has the relevant shape:

```haskell
mapException
    :: (Exception e1, Exception e2)
    => (e1 -> e2)
    -> a
    -> a
```

**Rationale**: the same failure can gain context as it moves outward: action, phase, selected wallet input, report destination, or intent network. That context should be data on the exception, not a string prefix. This mirrors the trace design: producers emit structured events, boundaries map or add context, and only the final tracer/renderer turns them into text.

Implementation note: `mapException` is the reference shape for pure exception mapping. Expected builder failures in this project mostly arise in `IO`, so a helper should expose the same `TreasuryBuildException -> TreasuryBuildException` transformation and apply it with typed `try`/`catch` where the exception is thrown with `throwIO`.

**Alternatives considered**:

- Prefix strings at each boundary. Rejected: loses structure and repeats the current `runSwap: build failed: ...` problem.
- Use only `ExceptT` and never throw. Rejected for compatibility wrappers and any existing exception-based boundary.
- Catch `SomeException` at the CLI and parse text. Rejected: brittle and loses typed information.

## D4. Public API shape

**Decision**: add a typed entry point such as `runFromIntentEither :: ChainContext -> SomeTreasuryIntent -> IO (Either TreasuryBuildError TreasuryBuildResult)`, then keep `runFromIntent` as a compatibility wrapper that throws a typed exception rendered from `TreasuryBuildError`.

**Rationale**: existing callers can keep using `runFromIntent`, while `app/Main.hs` can switch to the typed entry point and stop catching `SomeException` for expected builder failures.

**Alternatives considered**:

- Change `runFromIntent` directly to return `Either`. Rejected: broader churn for tests and any external users.
- Keep only the throwing API. Rejected: report failure envelopes are cleaner when built from structured errors, though `mapException` remains useful for compatibility and context enrichment.

## D5. InsufficientFee wording

**Decision**: label upstream values conservatively and avoid naming a raw input total as "shortfall". If a reliable derived gap is not available from the upstream constructor, the message should say that the balancer reported insufficient fee capacity and include labeled fields only.

**Rationale**: issue #64 showed that the raw constructor output can mislead operators. The point of normalization is to stop converting low-level tuple positions into incorrect English.

**Alternatives considered**:

- Compute `required - available` unconditionally. Rejected: the upstream values are not always the desired operator-level gap.
- Omit numeric fields. Rejected: operators still need evidence for debugging stale intents and protocol-parameter drift.

## D6. Failure codes

**Decision**: use stable lowercase hyphenated codes in `BuildFailure.bfCode`, for example:

- `insufficient-fee-capacity`
- `fee-not-converged`
- `collateral-shortfall`
- `script-evaluation-failed`
- `final-validation-failed`
- `fee-bump-failed`
- `fee-alignment-failed`
- `missing-utxos`
- `unsupported-action`

**Rationale**: report consumers should not scrape prose or Haskell constructor names.

**Alternatives considered**:

- Reuse upstream constructor names as codes. Rejected: dependency names are not the project contract.
- One generic `build-failed` code. Rejected: too coarse for automation and support triage.
