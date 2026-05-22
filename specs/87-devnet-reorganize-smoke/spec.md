# Feature Specification: live CLI reorganize through DevNet (#87)

**Feature Branch**: `87-devnet-reorganize-smoke`
**Created**: 2026-05-22
**Status**: Draft
**GitHub Issue**: [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87)
**Pull Request**: [#208](https://github.com/lambdasistemi/amaru-treasury-tx/pull/208) (draft)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189) — reorganize transaction end-to-end
**Feature Anchor**: [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
**Depends on (merged on `main`)**:

- [#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185) — `ReorganizeIntent` + `runReorganizeBuild` library core (merged `da9d65b5`)
- [#186](https://github.com/lambdasistemi/amaru-treasury-tx/issues/186) — `reorganize-wizard` parser scaffold (merged `1d99cd3b`)
- [#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187) — `reorganize-wizard` runner + DevNet guard (merged `3f48878d`)

**Sibling children (later, depend on this slice)**:

- [#188](https://github.com/lambdasistemi/amaru-treasury-tx/issues/188) — docs page + asciinema cast

**Input**: extend the existing CLI DevNet smoke harness (`scripts/smoke/smoke.sh`, `app/devnet-cli-smoke-host/Main.hs`, `just devnet-cli-smoke`) with a `reorganize` phase that exercises the live `reorganize-wizard --network devnet` runner shipped by #187 plus `tx-build`, proves multiple treasury UTxOs merge into a single continuing output, asserts asset preservation, and asserts that redeemer execution units sum to within `pparams.maxTxExecutionUnits.{memory,steps}`. Mirrors the upstream bash [`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh) and the [`assert_execution_units`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/assert_execution_units.sh) sanity check.

> **Scope framing:** this slice is the **DevNet boundary proof** for the operator path shipped by #185 → #187. It extends the existing harness; it does not introduce a new `smoke.sh`, a new host binary, or a new operator-facing CLI surface. Operator docs and the asciinema cast follow in #188.

## Carry-forward invariants (from #189)

- Construction lives in production library code (`Amaru.Treasury.Build.Reorganize`); smoke never rebuilds tx construction.
- Shipped CLI surface produces unsigned txs only. The smoke writes a `SomeTreasuryIntent` JSON via `reorganize-wizard`, then unsigned Conway CBOR via `tx-build --intent`. Signing or submission, if performed for setup or for the boundary proof, stays inside the DevNet harness and never via release-facing commands.
- Network safety is fail-closed at the wizard boundary (already shipped in #187).
- Phase-1 validation includes execution units: the smoke asserts the built tx's redeemer execution units sum to within `pparams.maxTxExecutionUnits.{memory,steps}`.
- Smoke is the operator/CLI proof layer (per #161). It must drive the shipped `amaru-treasury-tx` CLI and not re-enter in-process library runners. The static guard in `Amaru.Treasury.Smoke.CliDevnetSmokeSpec` continues to hold.

## Upstream parity reference

The upstream bash `reorganize.sh` chains:

1. parse / metadata load
2. wallet UTxO selection (`resolve_fuel`)
3. treasury UTxO selection (`select_treasury_utxos`)
4. validity bound
5. redeemer construction
6. `build_transaction`
7. submission to the upstream local network
8. `assert_execution_units` sanity check

The shipped CLI surface (post-#187) covers phases 1–6 by chaining `reorganize-wizard` (intent encode) and `tx-build` (unsigned CBOR). This slice ships the **boundary proof** that the chain produces ≥2 treasury UTxOs (phase 0 setup), drives 1–6 via the shipped CLI, then asserts (phase 8) via `cardano-tx-tools tx-validate`. Submission inside the DevNet harness is performed only when it is the cheapest way to fix the chain state to ≥2 treasury UTxOs; it is not the operator-facing P1 contract.

## User Scenarios & Testing

### User Story 1 — `just devnet-cli-smoke --phase reorganize` produces a live reorganize boundary proof (Priority: P1)

**As an operator validating the reorganize path against live local DevNet chain state**, I run

```bash
just devnet-cli-smoke --phase reorganize --run-dir runs/devnet-cli/<stamp>
```

against a freshly-bootstrapped DevNet. The smoke:

1. brings up the patched DevNet (via `devnet-cli-smoke-host`),
2. runs the prior `disburse` (and where required, additional setup) so the treasury at the `core_development` scope address carries ≥2 UTxOs,
3. invokes the shipped `amaru-treasury-tx reorganize-wizard --network devnet …` runner to produce `<run-dir>/phases/reorganize/intent.json`,
4. invokes the shipped `amaru-treasury-tx tx-build --intent <intent.json> --out <…>.unsigned.cbor` to produce unsigned Conway CBOR,
5. records selected input UTxOs, continuing output summary, asset preservation evidence (sum of inputs ≡ continuing output value, including all native assets), build log, epoch/tip context, and the run directory layout,
6. asserts via `cardano-tx-tools tx-validate` that the tx is Phase-1 valid against the live DevNet's protocol parameters, and additionally asserts the sum of redeemer execution units is within `pparams.maxTxExecutionUnits.{memory,steps}`,
7. exits 0 only when all of the above succeed.

**Why this priority**: this IS the parent epic #189 P1 contract for this child. The reorganize wizard + builder shipped in #185/#186/#187 are operator surfaces only — without this DevNet boundary proof, #189 cannot close. Every later release-facing claim that "reorganize works on Cardano" depends on this slice producing a live proof.

**Independent Test**: drive `just devnet-cli-smoke --phase reorganize --run-dir <tmp>` against a clean working tree; assert (1) exit code is 0, (2) `<tmp>/phases/reorganize/intent.json` decodes as `SomeTreasuryIntent SReorganize …`, (3) `<tmp>/phases/reorganize/reorganize.unsigned.cbor` exists and is non-empty, (4) `<tmp>/phases/reorganize/summary.json` carries selected-input UTxOs (≥2), continuing-output value, asset-preservation verdict, exec-units verdict, and run-dir paths, (5) the host-side assertion log records that the continuing output's value sum matches the input value sum across all asset classes, (6) the exec-units assertion records observed memory and steps both below the live `pparams.maxTxExecutionUnits` bounds.

**Acceptance Scenarios**:

1. **Given** a DevNet with the `core_development` treasury at ≥2 UTxOs after prior setup, **when** `just devnet-cli-smoke --phase reorganize` runs, **then** the smoke produces the intent JSON, unsigned CBOR, report JSON/Markdown, build log, selected input UTxOs, continuing output, asset preservation evidence, exec-units verdict, and a run directory, and exits 0.
2. **Given** a DevNet with the `core_development` treasury at fewer than 2 UTxOs and the smoke harness configured not to perform extra setup, **when** the smoke runs, **then** it exits with a typed diagnostic mapping to `ReorganizeInsufficientTreasuryUtxos` (exit 2) before any partial CBOR is produced, and `<run-dir>/phases/reorganize/diagnostics/` records the failure.
3. **Given** an `amaru-treasury-tx` binary that does not expose the `reorganize-wizard` subcommand (release-facing surface from #46 missing), **when** the smoke runs, **then** it exits with a typed `MISSING_REORGANIZE_BUILDER` diagnostic before any DevNet bring-up.
4. **Given** a built tx whose redeemer execution units exceed `pparams.maxTxExecutionUnits.{memory,steps}`, **when** the exec-units assertion runs against the run-dir CBOR, **then** the smoke exits with a typed `EXEC_UNITS_OVER_LIMIT` diagnostic and the summary records the observed and limit values.
5. **Given** a missing metadata file, missing scope owner, missing node socket, or any other typed `ReorganizeError`, **when** the smoke runs, **then** it surfaces the typed diagnostic and exits non-zero before claiming success.

### User Story 2 — `just devnet-cli-smoke --phase full` includes the reorganize boundary proof (Priority: P2)

**As CI / a release engineer**, I run

```bash
just devnet-cli-smoke --phase full
```

and observe that `full` chains `reorganize` after `disburse`, producing a unified `summary.json` that includes the `reorganizeSummary` alongside `registrySummary` / `governanceSummary` / `disburseSummary`. This guarantees that the full devnet pipeline always exercises reorganize.

**Why this priority**: P2 because P1 is the standalone `--phase reorganize` operator contract; this is the CI rollup.

**Independent Test**: drive `just devnet-cli-smoke --phase full`; assert `<run-dir>/phases/full/summary.json` carries the `reorganizeSummary` key, and `<run-dir>/phases/reorganize/` is fully populated.

## Deliverables

| Artifact | Surface(s) it lands on |
|---|---|
| `scripts/smoke/smoke.sh` — new `reorganize` phase + `MISSING_REORGANIZE_BUILDER` / `EXEC_UNITS_OVER_LIMIT` diagnostics | already shipped via the existing `just devnet-cli-smoke` recipe and the existing static guard in `Amaru.Treasury.Smoke.CliDevnetSmokeSpec` |
| `app/devnet-cli-smoke-host/Main.hs` — host dispatch for the `reorganize` phase (chain assertions, exec-units assertion) | already shipped as the `devnet-cli-smoke-host` executable; the new phase is recognized in the phase dispatch case |
| `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` — static guard updated to allow the new phase strings | already shipped as part of the unit suite |
| `specs/87-devnet-reorganize-smoke/` — spec/plan/tasks/quickstart for the slice | resolve-ticket asset, lives in tree like every other spec under `specs/` |
| Live run artifact reference paths under `<run-dir>/phases/reorganize/` (`intent.json`, `reorganize.unsigned.cbor`, `summary.json`, `diagnostics/`, `build.log`) | named in the spec, produced by the smoke at runtime — not committed |

**No new executable, library, or shipped CLI surface is introduced by this slice.** All work extends existing surfaces. The operator-facing reorganize CLI was shipped in #187; the docs + asciinema cast ship in #188 and are out-of-scope here.

**Asciinema scope note (per resolve-ticket spec rules):** because no new exe is shipped and no existing exe's flag surface changes (the smoke is a shell-side phase addition driving an already-shipped binary), the asciinema cast deliverable is owned by #188, not by this slice. The cast for the reorganize operator command will be recorded in #188 once docs ship.

## Out of scope

- Adding mainnet/preprod submission claims for reorganize.
- Operator docs page + asciinema cast (deferred to #188).
- Closing #46 (the feature anchor closes against whichever child ships the full operator surface; this slice does not change the operator surface).
- Multi-scope reorganize (one scope per smoke invocation, mirroring `reorganize.sh`).
- Replacing or refactoring `disburse_phase`, `governance_phase`, or any prior smoke phase.
- USDM-specific reorganize behavior.

## Constraints

- The smoke must stay inside the existing harness shape: extend, do not rewrite.
- The smoke must keep the no-in-process-runner contract enforced by `CliDevnetSmokeSpec`; new forbidden strings may be added, none may be removed.
- The reorganize phase must be safe under `--phase scaffold` (no DevNet required) so the static checks continue to pass without a live node.
- All diagnostics emitted on the failure path must be greppable: `MISSING_REORGANIZE_BUILDER`, `INSUFFICIENT_TREASURY_UTXOS`, `EXEC_UNITS_OVER_LIMIT`, `EXEC_UNITS_VALIDATOR_UNAVAILABLE`, `REORGANIZE_BUILD_FAILED`.
- The exec-units assertion must use the live DevNet's protocol parameters (via `cardano-tx-tools tx-validate` against the live N2C socket, or an equivalent live `queryProtocolParameters` path) — not a hard-coded fixture limit.

## Open clarifications

None. All scope decisions follow from the issue body, the epic invariants, and the existing harness shape.
