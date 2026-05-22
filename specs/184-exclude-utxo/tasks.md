---
description: "Task list for #184 — wizard input control via --exclude-utxo / --extra-tx-in"
---

# Tasks: wizard input control via `--exclude-utxo` / `--extra-tx-in`

**Input**: Design documents from `specs/184-exclude-utxo/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md)
**Tests**: Required. Every behavior-changing slice ships RED + GREEN in
one bisect-safe commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Parallel-safe inside the same slice only. It must not edit the
  same file as another active task.
- **[Story]**: Maps to the user stories in [spec.md](./spec.md) (US1
  exclude, US2 extra-in, US3 contradiction, US4 coverage).
- Paths are relative to the worktree root unless explicitly absolute.

## Slice and Commit Mapping

| Slice | Pair id (driver + navigator) | Primary story | Commit subject |
|---|---|---|---|
| 1 | `attx-184/slice-1-input-control` | US1+US2+US3 | `feat(wizard): shared InputControl module for --exclude-utxo / --extra-tx-in (#184)` |
| 2 | `attx-184/slice-2-swap-wiring`    | US4 (swap)  | `feat(swap-wizard): --exclude-utxo / --extra-tx-in (#184)` |
| 3 | `attx-184/slice-3-disburse-wiring`| US4 (disb.) | `feat(disburse-wizard): --exclude-utxo / --extra-tx-in for disburse + contingency-disburse (#184)` |
| 4 | `attx-184/slice-4-withdraw-wiring`| US4 (withd.)| `feat(withdraw-wizard): --exclude-utxo / --extra-tx-in (#184)` |
| 5 | `attx-184/slice-5-regsinit-wiring`| US4 (reg.)  | `feat(registry-init-wizard): --exclude-utxo / --extra-tx-in (#184)` |
| 6 | `attx-184/slice-6-stakeinit-wiring`| US4 (stk.) | `feat(stake-reward-init-wizard): --exclude-utxo / --extra-tx-in (#184)` |
| 7 | `attx-184/slice-7-govinit-wiring` | US4 (gov.)  | `feat(governance-withdrawal-init-wizard): --exclude-utxo / --extra-tx-in (#184)` |
| 8 | orchestrator                     | docs        | `docs: wizard input-control flag reference (#184)` |
| 9 | orchestrator                     | finalize    | `chore: drop gate.sh (ready for review)` (plus an orchestrator follow-up issue link in PR body before this commit) |

## Phase 1: Setup

No setup tasks. Branch, draft PR, accepted spec, accepted plan, and
`gate.sh` already exist.

## Phase 2: Slice 1 — Shared `InputControl` module + unit tests

**Goal**: Land the single source of truth for outref parsing,
exclusion/inclusion set types, contradiction validation, pool
filtering, optparse-applicative parsers, and error rendering so the
seven wizard slices that follow consume one tested API instead of
duplicating logic.

**Independent Test**: A new Hspec module
`test/unit/Amaru/Treasury/Wizard/InputControlSpec.hs` proves the
public API with focused RED-then-GREEN tests; the module is
not yet imported by any wizard so the slice is bisect-safe in
isolation.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). Driver holds the write lock; navigator reviews before
commit. One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Keep this slice to
the new shared module + tests + cabal exposure. The project builds
under `-Werror`: every API export MUST be exercised by
`InputControlSpec` or by `InputControlTestHelpers`, otherwise
`-Wunused-top-binds` will fail the slice — if you find yourself
exporting something the tests don't consume, drop the export and let
a later wiring slice add it via a forward extension. Commit body
MUST include `Tasks: T001, T002, T003, T004, T005`.

Owned files:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (new)
- `test/unit/Amaru/Treasury/Wizard/InputControlSpec.hs` (new)
- `test/unit/Amaru/Treasury/Wizard/InputControlTestHelpers.hs` (new — small fixtures + builders reused by Slices 2–7)
- `amaru-treasury-tx.cabal` (only to expose the new library module + new test-suite module)
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- any `lib/Amaru/Treasury/Cli/*.hs` (deferred to Slice 2+)
- any `lib/Amaru/Treasury/Tx/*Wizard*.hs` (deferred to Slice 2+)
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`, `docs/assets/asciinema/`

Tasks:

- [X] T001 [US1+US2] RED: write `InputControlSpec` assertions for `parseOutRef` — valid 64-char lowercase hex + `#` + non-negative index round-trips; uppercase hex rejected; missing `#` rejected; non-numeric index rejected; negative index rejected; index leading zeros accepted; surplus chars rejected. Tests fail because the module does not yet exist.
- [X] T002 [P] [US3] RED: extend `InputControlSpec` with `validateInputControl` assertions — disjoint sets pass; a single overlapping outref produces a structured `Contradiction <ref>` error; two overlapping refs produce both refs in the error in deterministic order.
- [X] T003 [P] [US1] RED: extend `InputControlSpec` with `filterPool` assertions — empty exclusion set is a no-op; single match removes one element and returns it in the "hit" set; multi match preserves remaining order; no match returns the original list unchanged; an "exclude-not-present-in-pool" case returns the original list AND records the inert excluded ref so callers can log it (per spec Edge Case "silently a no-op (with a log line)"); a forced-inclusion ref already present in the candidate pool is removed from the pool and emitted into the extras list exactly once (per FR-006 dedup invariant); multi-ref `--extra-tx-in` ordering is preserved in input order (per FR-006 "no silent reordering"); assertions also cover `renderShortfallWithExcludes` text shape (excluded refs listed in input order, no trailing newline, one ref per line).
- [X] T004 [US1+US2+US3] GREEN: implement `lib/Amaru/Treasury/Wizard/InputControl.hs` exporting `OutRef`, `parseOutRef`, `outRefText`, `ExclusionSet`, `ForcedInclusionSet`, `InputControlError(..)`, `validateInputControl`, `filterPool`, `excludeUtxoP`, `extraTxInP`, `renderInputControlError`, `renderShortfallWithExcludes`. Implement `test/unit/Amaru/Treasury/Wizard/InputControlTestHelpers.hs` with the small fixture builders Slices 2–7 will reuse (sample candidate lists, sample outrefs, builder for `(Text, Integer, Bool)` triples).
- [X] T005 GREEN: expose both new library modules + the new test-suite module in `amaru-treasury-tx.cabal`; run `./gate.sh` end-to-end and record the result in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. Shared module compiles and is
covered by unit tests; no wizard imports it yet. Slice is
bisect-safe: a previous commit reverts cleanly with no test regression.

## Phase 3: Slice 2 — `swap-wizard` end-to-end wiring (canary)

**Goal**: Prove the shared module's API in the most invasive wizard
runner. `swap-wizard` selects from both wallet and treasury pools and
has multiple resolver entry points (fixed-USDM, all-ADA), so wiring
it first surfaces any missing helper before the seven-wizard fanout.

**Independent Test**: New per-wizard test module
`test/unit/Amaru/Treasury/Cli/SwapWizardInputControlSpec.hs` proves
US1, US2, US3 against `swap-wizard`, and an extension to the existing
`SwapGolden` proves SC-005 (no-flag byte stability) on the existing
fixture.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Reuse the
`InputControl` API from Slice 1; do not duplicate parsing,
contradiction, or filter logic. Commit body MUST include
`Tasks: T006, T007, T008, T009, T010, T010a, T010b, T011, T012`.

Owned files:

- `lib/Amaru/Treasury/Cli/SwapWizard.hs`
- `lib/Amaru/Treasury/Tx/SwapWizard.hs` (only the call sites that
  call `selectWallet` / `selectTreasury`; do not touch the selectors
  themselves)
- `test/unit/Amaru/Treasury/Cli/SwapWizardInputControlSpec.hs` (new)
- `test/golden/Amaru/Treasury/Tx/SwapGoldenSpec.hs` (only if needed
  for SC-005 no-flag assertion; preserve the existing fixture)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen at Slice 1)
- any other wizard's `Cli/*Wizard.hs` or `Tx/*Wizard.hs`
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [X] T006 [US3] RED: assert that running `swap-wizard --exclude-utxo X --extra-tx-in X` (same outref both flags) exits non-zero with a structured `Contradiction` error before any chain query. Test fails because the flag is unwired.
- [X] T007 [P] [US1] RED: assert that with two candidate wallet UTxOs (`A` 92.56 ADA, `B` 19.76 ADA) and `--exclude-utxo <A>`, the wizard's emitted intent has `wallet.txIn = B` and the log records `swap-wizard: excluded utxo <A> (operator-supplied)`.
- [X] T008 [P] [US2] RED: assert that with `--extra-tx-in <R>` for a wallet UTxO present at the wallet address, the emitted intent has `wallet.extraTxIns` containing `<R>` exactly once and the primary `wallet.txIn` selection runs unchanged on the remaining pool.
- [X] T009 [P] [US1] RED: assert that with `--exclude-utxo` filtering all candidates from a pool that becomes empty, the wizard fails with `WalletNoPureAda` (or `WalletShortfall`) whose error message names every excluded outref via `renderShortfallWithExcludes`.
- [X] T010 [P] [US4] RED: assert SC-005 — running `swap-wizard` over the existing fixture with no `--exclude-utxo` or `--extra-tx-in` produces byte-identical intent bytes against the existing golden.
- [X] T010a [P] [US2] RED: assert FR-009 — passing `--extra-tx-in <R>` for an outref the wallet-address chain query does NOT return causes `swap-wizard` to exit non-zero with a structured "extra input not found on wallet" error naming `<R>`. This is the canary that proves the not-on-wallet contract on the most invasive runner; the same shape is reused in the per-wizard slices below.
- [X] T010b [P] [US1] RED: assert FR-005 pool attribution — when an excluded ref hits the wallet pool only, the log line names `wallet`; when it hits the treasury pool only, names `treasury`; when it hits both, names `both`. Use the multi-resolver shape of `swap-wizard` (which queries both pools) to cover all three branches in a single canary slice.
- [X] T011 [US1+US2+US3] GREEN: thread `ExclusionSet` / `ForcedInclusionSet` into `WizardOpts`, wire `excludeUtxoP` / `extraTxInP` into `wizardOptsP`, run `validateInputControl` at flag-validation time, and apply `filterPool` to wallet + treasury candidate sets in `resolveWizardEnv` (both pools), the all-ADA resolver, and `resolveSelections`. Emit forced-inclusion refs into the wizard output's `wallet.extraTxIns` (use the shared `InputControl` API; do not duplicate). Render shortfall errors via `renderShortfallWithExcludes`. Trace the `swap-wizard: excluded utxo <ref> (operator-supplied)` log line per excluded ref, including the pool attribution (`wallet`, `treasury`, or `both`). Resolve every `--extra-tx-in` ref against the wallet-query result; emit the FR-009 "extra input not found on wallet" error when any ref is missing. Note for the worker: the shared `InputControl` module from Slice 1 is FROZEN — needed extensions go in a forward slice, not via `git commit --amend` of Slice 1.
- [X] T012 GREEN: run `./gate.sh` end-to-end (which executes the new specs + the existing SwapGolden) and record the result in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. `swap-wizard --help` lists both
flags. The existing `swap` golden is byte-identical (no `wallet.txIn`
selection change). The new InputControlSpec from Slice 1 still passes.

## Phase 4: Slice 3 — `disburse-wizard` + `contingency-disburse-wizard` wiring

**Goal**: Cover the disburse runner, which is shared between
`disburse-wizard` and `contingency-disburse-wizard` and has both
wallet selection (`selectWallet walletFeeSlackLovelace`) and per-unit
treasury selection (`selectTreasuryForUnit`).

**Independent Test**: A new per-wizard test module proves US1, US2,
US3 against both `disburse-wizard` and `contingency-disburse-wizard`;
existing disburse-wizard fixtures
(`test/fixtures/disburse-wizard/expected.intent.ada.json` and
`.usdm.json`) prove SC-005.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Commit body MUST
include `Tasks: T013, T014, T015, T016, T017, T018, T019`.

Owned files:

- `lib/Amaru/Treasury/Cli/DisburseWizard.hs`
- `lib/Amaru/Treasury/Tx/DisburseWizard.hs` (call sites only)
- `test/unit/Amaru/Treasury/Cli/DisburseWizardInputControlSpec.hs` (new)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen)
- `lib/Amaru/Treasury/Cli/SwapWizard.hs`, `Tx/SwapWizard.hs`
- any non-disburse wizard's modules
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [X] T013 [US3] RED: contradiction error against `disburse-wizard` and against `contingency-disburse-wizard`.
- [X] T014 [P] [US1] RED: exclusion filters wallet pool for both wizards.
- [X] T015 [P] [US1] RED: exclusion filters the per-unit treasury pool (`selectTreasuryForUnit`) for the ADA path.
- [X] T016 [P] [US2] RED: forced inclusion lands in disburse intent's `wallet.extraTxIns` for both wizards.
- [X] T017 [P] [US1] RED: shortfall-with-excludes names excluded refs for both pools.
- [X] T018 [P] [US4] RED: SC-005 — byte-identical disburse intents against existing fixtures with no flags.
- [X] T019 [US1+US2+US3] GREEN: extend `DisburseWizardOpts` and `ContingencyDisburseOpts` with the shared field set (use the shared parser helpers from `InputControl`), wire `validateInputControl` at flag-validation time, apply `filterPool` to wallet AND per-unit treasury pools in `selectAndAssemble`, emit forced inclusions into the intent's `extraTxIns`, render shortfall errors via `renderShortfallWithExcludes`, trace per-wizard log lines with pool attribution (`disburse-wizard:`/`contingency-disburse-wizard:` prefix + `wallet`/`treasury`/`both` suffix), emit the FR-009 "extra input not found on wallet" error when any `--extra-tx-in` ref is missing from the wallet query, and run `./gate.sh`. Record the result in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. Both disburse-family wizards
list the flags in `--help`. Existing ADA + USDM fixtures byte-identical.

## Phase 5: Slice 4 — `withdraw-wizard` wiring

**Goal**: Wire the flags into `withdraw-wizard` (single `selectWallet 1`
call site in `Tx/WithdrawWizard.hs:440`).

**Independent Test**: New per-wizard test module proves US1, US2, US3
against `withdraw-wizard`; existing withdraw golden proves SC-005.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Commit body MUST
include `Tasks: T020, T021, T022, T023, T024`.

Owned files:

- `lib/Amaru/Treasury/Cli/WithdrawWizard.hs`
- `lib/Amaru/Treasury/Tx/WithdrawWizard.hs` (call site only)
- `test/unit/Amaru/Treasury/Cli/WithdrawWizardInputControlSpec.hs` (new)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen)
- any other wizard's modules
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [X] T020 [US3] RED: contradiction against `withdraw-wizard`.
- [X] T021 [P] [US1] RED: exclusion filters wallet pool.
- [X] T022 [P] [US2] RED: forced inclusion lands in withdraw intent's `wallet.extraTxIns`.
- [X] T023 [P] [US1+US4] RED: shortfall-with-excludes names excluded refs; SC-005 byte stability against existing withdraw fixture.
- [X] T024 [US1+US2+US3] GREEN: extend `WithdrawOpts` and `withdrawOptsP`, wire validation + filter + intent emission (with FR-009 not-on-wallet error) + error rendering + log line (with `wallet`/`treasury`/`both` pool attribution), run `./gate.sh`, record in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. `withdraw-wizard --help` lists
the flags. Existing withdraw fixture byte-identical.

## Phase 6: Slice 5 — `registry-init-wizard` wiring

**Goal**: Wire the flags into `registry-init-wizard` (two
`selectWallet 1` call sites in `Tx/RegistryInitWizard.hs:306` and
`:401` for seed-split and reference-scripts modes).

**Independent Test**: New per-wizard test module proves US1, US2, US3
against `registry-init-wizard` for at least one mode (seed-split is
the primary); existing fixtures
(`test/fixtures/registry-init-wizard/*.json`) prove SC-005 across all
three modes.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Commit body MUST
include `Tasks: T025, T026, T027, T028, T029`.

Owned files:

- `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`
- `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` (call sites only)
- `test/unit/Amaru/Treasury/Cli/RegistryInitWizardInputControlSpec.hs` (new)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen)
- any other wizard's modules
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [ ] T025 [US3] RED: contradiction against `registry-init-wizard` (seed-split mode).
- [ ] T026 [P] [US1] RED: exclusion filters wallet pool in seed-split mode.
- [ ] T027 [P] [US2] RED: forced inclusion lands in seed-split intent's `wallet.extraTxIns`.
- [ ] T028 [P] [US1+US4] RED: shortfall-with-excludes naming + SC-005 byte stability against existing seed-split, mint, reference-scripts fixtures.
- [ ] T029 [US1+US2+US3] GREEN: extend `RegistryInitWizardOpts` and `registryInitWizardOptsP`, wire validation + filter + intent emission (with FR-009 not-on-wallet error) + error rendering + log line (with `wallet`/`treasury`/`both` pool attribution) at BOTH call sites (`selectWallet 1` at lines ~306 AND ~401 — wiring only one will fail T028's all-modes byte-stability assertion), run `./gate.sh`, record in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. `registry-init-wizard --help`
lists the flags. All three mode fixtures byte-identical.

## Phase 7: Slice 6 — `stake-reward-init-wizard` wiring

**Goal**: Wire the flags into `stake-reward-init-wizard` (single
`selectWallet 1` call site in
`Tx/StakeRewardInitWizard.hs:303`).

**Independent Test**: New per-wizard test module proves US1, US2, US3
against `stake-reward-init-wizard`; existing fixtures
(`test/fixtures/stake-reward-init-wizard/*.json`) prove SC-005.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Commit body MUST
include `Tasks: T030, T031, T032, T033, T034`.

Owned files:

- `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`
- `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` (call site only)
- `test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardInputControlSpec.hs` (new)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen)
- any other wizard's modules
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [ ] T030 [US3] RED: contradiction against `stake-reward-init-wizard`.
- [ ] T031 [P] [US1] RED: exclusion filters wallet pool.
- [ ] T032 [P] [US2] RED: forced inclusion lands in intent's `wallet.extraTxIns`.
- [ ] T033 [P] [US1+US4] RED: shortfall-with-excludes naming + SC-005 byte stability against existing fixtures.
- [ ] T034 [US1+US2+US3] GREEN: extend opts + parser, wire validation + filter + intent emission (with FR-009 not-on-wallet error) + error rendering + log line (with pool attribution), run `./gate.sh`, record in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD. `stake-reward-init-wizard --help`
lists the flags. Existing fixtures byte-identical.

## Phase 8: Slice 7 — `governance-withdrawal-init-wizard` wiring

**Goal**: Wire the flags into `governance-withdrawal-init-wizard`,
which uses a different selector (`firstPureAdaRef`) at two call sites
(`Tx/GovernanceWithdrawalInitWizard.hs:684` for proposal,
`:1075` for materialization). The shared `filterPool` runs *before*
`firstPureAdaRef`, so the selector itself stays untouched.

**Independent Test**: New per-wizard test module proves US1, US2, US3
against the wizard for at least the proposal path; existing fixtures
(`test/fixtures/governance-withdrawal-init-wizard/*.json`) prove
SC-005.

**Worker brief**: New driver+navigator pair (Claude Opus medium
effort). One bisect-safe commit. Do not push. You are not alone in
the codebase; do not revert edits made by others. Commit body MUST
include `Tasks: T035, T036, T037, T038, T039`.

Owned files:

- `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`
- `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` (call
  sites only; `firstPureAdaRef` itself stays unchanged)
- `test/unit/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizardInputControlSpec.hs` (new)
- `amaru-treasury-tx.cabal` (only to expose the new test module)
- `WIP.md` (ephemeral)

Forbidden scope:

- `lib/Amaru/Treasury/Wizard/InputControl.hs` (frozen)
- any other wizard's modules
- `specs/`, `gate.sh`, README, `docs/`, PR metadata
- `.github/`, `flake.nix`, `nix/`, `mkdocs.yml`,
  `docs/assets/asciinema/`

Tasks:

- [ ] T035 [US3] RED: contradiction against `governance-withdrawal-init-wizard` (proposal path).
- [ ] T036 [P] [US1] RED: exclusion filters wallet pool — `firstPureAdaRef` returns the next pure-ADA ref after the excluded one is removed.
- [ ] T037 [P] [US2] RED: forced inclusion lands in proposal intent's `wallet.extraTxIns`.
- [ ] T038 [P] [US1+US4] RED: shortfall-with-excludes naming (no pure-ADA candidates remain after exclusion) + SC-005 byte stability against the existing proposal fixture.
- [ ] T039 [US1+US2+US3] GREEN: extend opts + parser, wire validation + filter + intent emission (with FR-009 not-on-wallet error) + error rendering + log line (with pool attribution) at BOTH call sites (proposal at line ~684 AND materialization at ~1075 — wiring only one will fail T038's byte-stability assertion across both paths), run `./gate.sh`, record in `WIP.md`.

Checkpoint: `./gate.sh` PASS at HEAD.
`governance-withdrawal-init-wizard --help` lists the flags. Existing
fixtures byte-identical.

## Phase 9: Slice 8 — Documentation (orchestrator-owned)

**Goal**: Document the new flags in the wizard-facing pages and add a
short shared page describing the flag semantics, the contradiction
error, and the in-flight-build motivation.

**Independent Test**: `./gate.sh` PASS (no behavioral tests
required; docs are non-behavioral). New shared page is linked from
`docs/index.md`'s command table; each per-wizard page mentions the
flags with the same phrasing.

**Worker brief**: Orchestrator-owned per the resolve-ticket
invariant "the orchestrator may directly do non-behavioral
mechanical edits: docs, PR body, metadata, …". No driver/navigator
pair dispatched.

Owned files:

- `docs/wizard-input-control.md` (new)
- `docs/index.md`
- `docs/swap.md`
- `docs/disburse.md`
- `docs/withdraw.md`
- `README.md` (only if it shows a wizard command example today)

Tasks:

- [ ] T040 [US4] Author `docs/wizard-input-control.md`: outref format, `--exclude-utxo` semantics, `--extra-tx-in` semantics, contradiction error, in-flight-build motivation, pointer at #183 as the principled auto-detection layer.
- [ ] T041 [P] [US4] Add a one-line flag reference to `docs/swap.md` linking the new shared page.
- [ ] T042 [P] [US4] Add a one-line flag reference to `docs/disburse.md` linking the new shared page (covers both disburse and contingency-disburse).
- [ ] T043 [P] [US4] Add a one-line flag reference to `docs/withdraw.md` linking the new shared page.
- [ ] T044 Update `docs/index.md`'s command table footer to mention the shared input-control page.
- [ ] T045 [P] If `README.md` quickstart shows a wizard command, add a one-line pointer at the shared page; otherwise no-op.
- [ ] T045a [US4] FR-011 parity verification: assert that the seven wizards' `--help` output for `--exclude-utxo` and `--extra-tx-in` is byte-identical across wizards. Recommended implementation: a thin Hspec spec that captures `<wizard> --help` for each in-scope wizard and asserts the substring describing the two flags is identical. If structural reasons make a runtime test impractical, document in `docs/wizard-input-control.md` that parity is guaranteed by every wizard consuming the same `excludeUtxoP` / `extraTxInP` helpers from `Wizard.InputControl`, and link to the helper source.

Checkpoint: `./gate.sh` PASS at HEAD. Shared docs page exists; per-wizard
pages link it; `docs/index.md` advertises it.

## Phase 10: Slice 9 — Finalize (orchestrator-owned)

**Goal**: File the asciinema follow-up issue, update the PR body with
the issue link, then drop `gate.sh` in the final
`chore: drop gate.sh (ready for review)` commit and mark PR #200
ready. The absence of `gate.sh` at HEAD is the readiness sentinel.

**Worker brief**: Orchestrator-owned. No driver/navigator pair
dispatched.

Owned files:

- `gate.sh` (removed)
- PR body (via `gh pr edit`)
- new GitHub issue (via `gh issue create`)

Tasks:

- [ ] T046 Re-read the spec's Acceptance items SC-001 through SC-006 against HEAD before the drop commit (NOT against a merged-state branch — this slice precedes merge); record outcome in PR body. Verify FR-001 through FR-013 each have a backing commit on the branch (commit body `Tasks:` trailer or orchestrator-owned slice).
- [ ] T047 File the asciinema follow-up issue ("adopt mkdocs `asciinema-player` plugin + record wizard input-control cast for #184"). Capture the issue URL.
- [ ] T048 Update PR #200 body with: completed acceptance summary, link to the new docs page, link to the asciinema follow-up issue, restated sibling relationship to #183.
- [ ] T049 Re-run `./gate.sh` to confirm green at HEAD before the drop commit.
- [ ] T050 Commit `chore: drop gate.sh (ready for review)` (orchestrator-owned, no `Tasks:` trailer required for `chore:` per the commit gate), push, then `gh pr ready 200`.

Checkpoint: PR is ready for external review. No `gate.sh` at HEAD.
PR body cites the asciinema follow-up issue.
