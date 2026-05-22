# Implementation Plan — #87 DevNet reorganize smoke

**Branch**: `87-devnet-reorganize-smoke`
**Spec**: [spec.md](./spec.md)

## Orchestration / subagent ownership

- The ticket-orchestrator (this agent) owns spec/plan/tasks/PR metadata, the gate.sh, and the final `chore: drop gate.sh` slice.
- Every behavior-changing slice is dispatched to a Claude Code driver+navigator pair (effort `high`) per the ticket-orchestrator brief.
- No slice exceeds one bisect-safe commit.
- The `Amaru.Treasury.Smoke.CliDevnetSmokeSpec` forbidden-string contract is owned by the orchestrator (any update lands in the slice that needs it; the orchestrator reviews the change explicitly).

## Top-level slicing

The work decomposes into four bisect-safe slices, ordered:

1. **S1 — `reorganize` phase scaffold + missing-builder guard.** Adds the `reorganize` phase token to `scripts/smoke/smoke.sh` and `app/devnet-cli-smoke-host/Main.hs`, the `MISSING_REORGANIZE_BUILDER` boundary check (run before any DevNet bring-up), and the phase-recognized branch under `--phase scaffold` / `--phase preflight`. No live DevNet work yet. Extends `CliDevnetSmokeSpec` with the new phase strings and asserts the `MISSING_REORGANIZE_BUILDER` diagnostic is produced when the shipped binary is stubbed to a non-reorganize variant. Slice owns: one focused unit/static fixture.
2. **S2 — Live reorganize phase body.** Implements the live `reorganize_phase` in `smoke.sh` (treasury-utxo-count check, optional setup to reach ≥2 UTxOs, `reorganize-wizard` invocation, `tx-build` invocation, run-dir artifact layout, `summary.json`) plus the host-side chain assertions for asset preservation and continuing output. Extends `full_phase` to chain `reorganize` after `disburse`. Slice owns: one host-side assertion that fails loudly when the continuing output's value sum diverges from input value sum across all assets.
3. **S3 — Exec-units assertion.** Adds the `EXEC_UNITS_OVER_LIMIT` / `EXEC_UNITS_VALIDATOR_UNAVAILABLE` diagnostics; invokes `cardano-tx-tools tx-validate` (or equivalent live protocol-params + redeemer-evaluation path) against the run-dir CBOR; asserts the redeemer execution units sum is within the live `pparams.maxTxExecutionUnits.{memory,steps}`. Slice owns: one focused host-side assertion that loads the protocol params from the running node, parses the tx-validate output, and writes the verdict to `summary.json`.
4. **S4 — Finalization.** `chore: drop gate.sh (ready for review)` slice owned by the orchestrator.

## Proof strategy per slice

| Slice | RED proof | GREEN evidence |
|---|---|---|
| S1 | New `CliDevnetSmokeSpec` cases assert (a) `reorganize` phase token is forbidden until the smoke recognizes it and (b) running a fake `amaru-treasury-tx` without a `reorganize-wizard` subcommand produces the `MISSING_REORGANIZE_BUILDER` diagnostic before any DevNet bring-up. Both fail on `origin/main`. | Phase recognition lands and the unit suite goes green. `./gate.sh` PASS. |
| S2 | Hspec-driven integration test that builds a fixture `<run-dir>` with one treasury UTxO and asserts the smoke exits with `INSUFFICIENT_TREASURY_UTXOS`; a second case with ≥2 UTxOs asserts the smoke writes `intent.json`, unsigned CBOR, and a `summary.json` whose continuing-output value sum equals the input value sum across all assets. Both fail on `origin/main`. | Live `just devnet-cli-smoke --phase reorganize --run-dir <tmp>` exits 0 on the happy path; host-side assertion log carries the value-preservation verdict; `./gate.sh` PASS. |
| S3 | Hspec/unit test feeds the assertion a captured `tx-validate` JSON output where exec-units exceed a synthetic `pparams.maxTxExecutionUnits` and asserts `EXEC_UNITS_OVER_LIMIT`; a happy-path fixture asserts the verdict is recorded with both observed and limit values. Both fail on `origin/main`. | Live smoke records the exec-units verdict in `summary.json`; `./gate.sh` PASS. |
| S4 | n/a | Orchestrator-owned drop of `gate.sh`; final gate runs green at HEAD. |

## Live-boundary diagnostic (mandatory per resolve-ticket)

**Question:** what system boundary does this PR exercise that the unit suite cannot?

**Answer:** the live cardano-node N2C socket. The wizard's resolver queries treasury and wallet UTxOs over N2C; `tx-build` consumes the resolved intent; `tx-validate` runs Phase-1 against the same socket. Unit tests can mock the resolver, but only a live node can prove (a) the treasury-address query observes exactly the UTxO set the harness produced, (b) the built tx is Phase-1 valid against the live protocol parameters, and (c) the redeemer execution units sum is within the live `pparams.maxTxExecutionUnits`. The live-boundary smoke IS this slice's deliverable — it lives in `./gate.sh` as part of `just devnet-cli-smoke --phase reorganize` (slow but conclusive). The unit suite stays at the static-guard layer (`CliDevnetSmokeSpec`).

## Owned files (by slice)

The orchestrator enforces these boundaries in the driver/navigator brief. Files outside the owned set in a slice are forbidden scope.

- **S1**
  - `scripts/smoke/smoke.sh` (phase token + MISSING_REORGANIZE_BUILDER guard + scaffold/preflight branches)
  - `app/devnet-cli-smoke-host/Main.hs` (phase dispatch case)
  - `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` (allowed-phase list + missing-builder fixture)
  - `gate.sh` (extend if a focused unit invocation is needed beyond `just ci`)
- **S2**
  - `scripts/smoke/smoke.sh` (live `reorganize_phase`, full-phase chain)
  - `app/devnet-cli-smoke-host/Main.hs` (host-side chain assertions for reorganize, full-phase summary key)
  - `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` (additional fixtures only; no relaxation of forbidden strings)
  - `gate.sh` (extend to invoke `just devnet-cli-smoke --phase reorganize` as the live-boundary leg, deferred to operator follow-up if the gate cannot afford a full DevNet bring-up — see "gate.sh strategy" below)
- **S3**
  - `scripts/smoke/smoke.sh` (`tx-validate` invocation + exec-units assertion glue)
  - `app/devnet-cli-smoke-host/Main.hs` (assertion plumbing for exec-units; protocol-params load)
  - `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` (exec-units assertion unit test)
  - `gate.sh` (no change in S3 if S2 already wired the live leg)
- **S4** (orchestrator-owned)
  - `gate.sh` (deleted in `chore: drop gate.sh`)

## gate.sh strategy

`gate.sh` already runs `just ci` (build + unit + golden + format + hlint + smoke + release-check) and the commit-message gate. The static unit guard in `CliDevnetSmokeSpec` ships under `just unit`, so S1's RED/GREEN proof rides in the existing gate without extra lines.

The **live-boundary leg** (`just devnet-cli-smoke --phase reorganize`) is too slow and too dependent on a working DevNet to run on every push. Per the live-boundary-smoke playbook, this becomes an operator-follow-up gate:

- The unit suite carries fixture-based assertions for every diagnostic and verdict path.
- A named operator follow-up — recorded in this plan and reproduced in `summary.json` — runs `just devnet-cli-smoke --phase reorganize` before the PR is marked ready. The orchestrator captures the run-dir layout and pastes the relevant `summary.json` snippets into the PR body as live-boundary evidence.

This follow-up is the orchestrator's pre-ready check, not a worker task. Owner: ticket-orchestrator. Verifiable artifact: `summary.json` excerpt in PR body + run-dir tarball reference.

## Risk register

| Risk | Mitigation |
|---|---|
| Treasury at `core_development` carries only 1 UTxO after `disburse_phase` ends. | S2 explicitly inspects the treasury-utxo count; if <2, it runs an additional setup sub-step inside the DevNet harness (a second small disbursement or a direct split) that ALWAYS lands inside the host's signing/submission scope, never via release-facing commands. The smoke fails closed with `INSUFFICIENT_TREASURY_UTXOS` if setup cannot reach ≥2. |
| `cardano-tx-tools tx-validate` schema drift between versions. | S3 pins behavior by parsing only the documented `--output json` shape; on parse failure it emits `EXEC_UNITS_VALIDATOR_UNAVAILABLE` (exit non-zero) so a future version bump fails loudly. |
| Live `pparams.maxTxExecutionUnits` differs between Conway eras. | S3 reads the limits from the live node at assertion time (no hard-coded constant), so the assertion is automatically correct for whatever era the DevNet is running. |
| Concurrent DevNet bring-up conflicts with another smoke phase. | Existing harness already uses `withCardanoNode`; reorganize phase inherits the same lifecycle. No new lifecycle concerns. |
| Static guard in `CliDevnetSmokeSpec` over-fits the phase string and breaks unrelated work. | Phase strings are added to an explicit allow-list (not a regex); other phases are unchanged. |

## Carry-forward to #188

#188 (docs page + asciinema cast) consumes:

- The exact `just devnet-cli-smoke --phase reorganize` operator command.
- The `<run-dir>/phases/reorganize/` layout this slice establishes.
- The diagnostic codes (`MISSING_REORGANIZE_BUILDER`, `INSUFFICIENT_TREASURY_UTXOS`, `EXEC_UNITS_OVER_LIMIT`, `EXEC_UNITS_VALIDATOR_UNAVAILABLE`, `REORGANIZE_BUILD_FAILED`).

The plan does not pre-commit to a docs path; #188 will choose.
