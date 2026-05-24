# T001 — Audit: every exit-on-error site in `lib/Amaru/Treasury/Build/Swap.hs`

Walk of `runSwap` + `runSwapAction` at commit `188c2ca1`. 255-line file. Five exit sites; four are already typed via `ExceptT ActionBuildError`, one is an unchecked `error`.

## Site map

| # | Line | Source                                                          | Mechanism                | Already typed?                                  | Notes |
|---|------|-----------------------------------------------------------------|--------------------------|-------------------------------------------------|-------|
| 1 | 127  | `throwE (missingUtxosError missing)`                            | `throwE` → `ExceptT`     | yes — `BuildPhaseGatherInputs` + `DiagnosticMissingUtxos [Text]` | Fires when any required input (wallet UTxO, extra wallet inputs, treasury UTxOs, the four `*DeployedAt` references) is absent from the supplied `ChainContext.ccUtxos`. |
| 2 | 158  | `error "treasury build: unexpected context request"`            | partial-function `error` | **NO**                                          | Inside the `noCtxIO :: InterpretIO q` lambda. Triggered if `Cardano.Tx.Build.build` ever asks for a value via the `InterpretIO` callback during this build path. Conceptually unreachable for swap (the program doesn't request external context), but the type system doesn't enforce that. **Action**: replace with `throwE (actionBuildError BuildPhaseBuild (DiagnosticTranslateFailed "..."))` so the bound is total, OR keep the `error` with a `# Justification:` comment proving the call is unreachable via static argument of `swapProgram` not invoking the lambda. Decision deferred to T008 walk. |
| 3 | 171  | `throwE $ actionBuildError BuildPhaseBuild (diagnosticFromTxBuildError e)` | `throwE` → `ExceptT`     | yes — `BuildPhaseBuild` + `BuildDiagnostic` projected from `TxBuild.BuildError ()` | Wraps the `Left` arm of the underlying `Cardano.Tx.Build.build` call. `diagnosticFromTxBuildError` (in `Build.Error.Convert`) is the projection — it handles balance / fee / collateral / script-eval cases. |
| 4 | 183  | `throwE $ actionBuildError BuildPhaseFeeAlignment (DiagnosticFeeAlignmentFailed (T.pack e))` | `throwE` → `ExceptT`     | yes — `BuildPhaseFeeAlignment` + `DiagnosticFeeAlignmentFailed Text` | Fires when `alignCardanoCliBuildFee` returns `Left e`. |
| 5 | 190  | `throwE $ actionBuildError BuildPhaseBuild (DiagnosticChecksFailed e)` | `throwE` → `ExceptT`     | yes — `BuildPhaseBuild` + `DiagnosticChecksFailed Text` | Fires when `validateFinalPhase1 ctx tx` returns `Left e`. |

## Reconciliation against `BuildDiagnostic`

Existing `Amaru.Treasury.Build.Error.Types.BuildDiagnostic` constructor list (commit `188c2ca1`):

| Constructor                                            | Reachable from `Build.Swap`?     | Triggering site                                          |
|--------------------------------------------------------|----------------------------------|----------------------------------------------------------|
| `DiagnosticScriptEvaluationFailed Text Text`           | yes (via site 3 projection)      | underlying `TxBuild.build` returns a script-eval `Left`. |
| `DiagnosticInsufficientFee Coin Coin`                  | yes (via site 3 projection)      | balance error: not enough lovelace to cover fee.         |
| `DiagnosticFeeNotConverged`                            | yes (via site 3 projection)      | balance fix-point did not converge.                      |
| `DiagnosticCollateralShortfall Coin Coin`              | yes (via site 3 projection)      | balance error: collateral shortfall.                     |
| `DiagnosticChecksFailed Text`                          | yes — site 5                     | `validateFinalPhase1` post-build assertion failure.      |
| `DiagnosticBumpFeeFailed Text`                         | yes (via site 3 projection)      | rare — fee-bump path used inside `build`.                |
| `DiagnosticMissingUtxos [Text]`                        | yes — site 1                     | gather-inputs predicate failed.                          |
| `DiagnosticFeeAlignmentFailed Text`                    | yes — site 4                     | `alignCardanoCliBuildFee` rejected the post-build body.  |
| `DiagnosticTranslateFailed Text`                       | not yet — would be site 2 if replaced | proposed home for the unchecked `error` at line 158.     |
| `DiagnosticUnsupportedAction Text`                     | no                               | raised by dispatcher (`Build.hs`), not by the swap path. |
| `DiagnosticUnsupportedNetwork Text`                    | no                               | raised by `requireDevnet` for init sub-actions only.     |

**Coverage for the harness (T006, FR-007, SC-002)**: the per-variant harness must reach the 8 constructors flagged "yes" against `Build.Swap`. The remaining 3 (`DiagnosticTranslateFailed`, `DiagnosticUnsupportedAction`, `DiagnosticUnsupportedNetwork`) belong to adjacent code paths and are out of scope for this slice's harness coverage.

## Implications for tasks

- **T003 (`BuildEvent`)**: still needed — no existing event taxonomy for the build phase. Constructor set unchanged from `data-model.md § 2`.
- **T004 (`BuildFailure` sum type)**: **dropped**. Re-export `ActionBuildError` (and its embedded `BuildDiagnostic`) from `Wizard.Failure` under the alias `BuildFailure` — zero new constructors invented. Task becomes:
  - Add `import Amaru.Treasury.Build.Error.Types (ActionBuildError (..), BuildDiagnostic (..))` to `Wizard.Failure`.
  - Re-export `ActionBuildError` as `BuildFailure` for symmetry with `WizardFailure` at call sites.
- **T005 (`sysexitsForBuild`)**: still needed. Maps `BuildDiagnostic` constructors to sysexits per the 64/69/70 taxonomy: `DiagnosticMissingUtxos` / `DiagnosticUnsupportedNetwork` → 64 (usage); script-eval / balance / collateral / fee-converge → 70 (internal-software); checks-failed / fee-alignment / bump-fee / translate → 70 (internal-software). No mapping today is 69 (unavailable) — that family belongs to backend-unavailable errors which surface from `Backend` calls in `buildSwapIntent`, NOT from `buildSwapTx`.
- **T008 (implementation)**: not a rewrite of `runSwapAction` — `buildSwapTx` is a *wrapper* around `runSwapAction` that converts `BuildResult → TxBuildSuccess` and exposes the `ExceptT`-arm directly via `IO (Either ActionBuildError TxBuildSuccess)`. Plus the site-2 decision (replace `error` with typed variant OR justify unreachability).
- **T011 (delete legacy exit paths)**: there are none in `Build.Swap` itself — the only legacy host-termination path was `runActionBuild`'s `throwBuildException` in `Error.Convert`. That stays put for the CLI shim's continued use; the new typed `buildSwapTx` simply bypasses it.

## Conclusion

The refactor is much smaller than the original spec implied. The codebase already has a typed failure taxonomy. The work is:
1. Plumb `runSwapAction` → `TxBuildSuccess` through `Wizard.Swap.buildSwapTx`.
2. Add the `BuildEvent` tracer plane.
3. Add `sysexitsForBuild`.
4. Decide what to do with the line-158 `error`.
5. Extend the HTTP response + frontend tabs.

All 11 existing `BuildDiagnostic` constructors are kept; **no new failure types invented.**
