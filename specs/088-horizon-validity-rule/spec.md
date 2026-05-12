# Feature Specification: Chain horizon governs validity-upper-bound

**Feature Branch**: `feat/088-validity-hours-week`
**Created**: 2026-05-12
**Status**: Draft
**Issue**: [lambdasistemi/amaru-treasury-tx#88](https://github.com/lambdasistemi/amaru-treasury-tx/issues/88)
**PR**: [lambdasistemi/amaru-treasury-tx#89](https://github.com/lambdasistemi/amaru-treasury-tx/pull/89)
**Depends on**: `cardano-node-clients` `Validity.queryUpperBoundSlot` ([PR #134 merged](https://github.com/lambdasistemi/cardano-node-clients/pull/134))
**Input**: "The CAP is coming from the real conditions of the blockchain and without explicit validity range we are going to be assigned the CAP itself."

## Background — why this rescopes #88

The original ticket asked to "raise the static `--validity-hours` cap from 48 to 168" so operators could prepare multi-day signing windows. While exercising that against live mainnet we discovered the cap is a fiction: the chain's plutus-translation horizon already limits how far `invalid-hereafter` can be set, and the limit moves with epoch position. A static `[1, 168]` window either rejects values that would build fine near a safe-zone boundary, or accepts values that crash mid-build with `TimeTranslationPastHorizon`.

The honest rule is "the chain horizon is the cap". This spec rewrites the wizard contract accordingly.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator omits `--validity-hours` (Priority: P1)

Operator runs `swap-wizard …` (or `disburse-wizard`, `withdraw-wizard`) without specifying `--validity-hours`. The wizard picks the longest currently-buildable upper bound — i.e. the chain horizon at the moment the wizard runs — and emits that as `validityUpperBoundSlot` in `intent.json`.

**Why this priority**: This is the new default behavior. Most operators don't have a specific signing-window policy; they want the chain to tell them.

**Independent Test**: Against live mainnet, omit `--validity-hours`. Pipe the intent into `tx-build`. The resulting CBOR's `invalid-hereafter` slot is exactly the value `Validity.queryUpperBoundSlot AutoLongest` returns at the same moment.

**Acceptance Scenarios**:

1. **Given** a synced mainnet node mid-epoch, **When** `swap-wizard --wallet-addr … --scope network_compliance --usdm 100000 …` runs without `--validity-hours`, **Then** the emitted `intent.json` carries `validityUpperBoundSlot` equal to `Validity.queryUpperBoundSlot AutoLongest`'s result.
2. **Given** the same conditions, **When** the intent is fed to `tx-build`, **Then** script evaluation succeeds (no `TimeTranslationPastHorizon`).
3. **Given** a node whose tip is inside the safe zone of an era boundary, **When** the wizard runs without `--validity-hours`, **Then** the emitted slot extends past the era boundary as the helper allows.

---

### User Story 2 — Operator passes a within-horizon `--validity-hours N` (Priority: P1)

Operator runs `swap-wizard --validity-hours 24 …` mid-epoch. The wizard picks `tip + 24*3600` and validates it against the chain horizon via the helper; the request fits, so the wizard emits that slot.

**Why this priority**: This preserves the existing "I want exactly this signing window" use case for operators with a policy below the chain horizon.

**Independent Test**: Run the wizard with `--validity-hours 24` against live mainnet. The emitted `validityUpperBoundSlot` equals `Validity.queryUpperBoundSlot (ExactlyHours 24)`'s result for the same tip.

**Acceptance Scenarios**:

1. **Given** chain horizon ≥ 24 h, **When** `swap-wizard --validity-hours 24` runs, **Then** the wizard succeeds and `validityUpperBoundSlot = tip + 24*3600`.
2. **Given** the same conditions, **When** the intent is built, **Then** script evaluation succeeds.

---

### User Story 3 — Operator passes a `--validity-hours N` that overshoots the horizon (Priority: P1)

Operator runs `swap-wizard --validity-hours 120 …` mid-epoch. The chain horizon today only allows ≈ 60 h. The wizard refuses at the resolver step with a typed error that names the requested slot, the horizon slot, the tip, and the requested hours — operator sees a clean diagnostic before any tx-build work happens.

**Why this priority**: This is the bug we're fixing. Without it, the 120 h request previously crashed inside `tx-build`'s script evaluation with a 1 KB internal stack dump.

**Independent Test**: Run `swap-wizard --validity-hours 120` mid-epoch (horizon ≈ 60 h). The wizard exits non-zero with a typed `WizardValidityOvershoot` (or equivalent) carrying the four fields. No `intent.json` is produced; no `tx-build` is invoked.

**Acceptance Scenarios**:

1. **Given** chain horizon < 120 h, **When** the wizard runs with `--validity-hours 120`, **Then** it exits non-zero with a single trace line naming the requested slot, the horizon slot, the tip, and the requested hours.
2. **Given** the same overshoot, **When** the error is printed, **Then** the message is short enough to read at a glance (no nested stack traces).

---

### User Story 4 — Operator passes `--validity-hours 0` (Priority: P2)

Zero hours is nonsense regardless of chain state; the wizard rejects it as before.

**Why this priority**: Cheap defensive check; the old guard already covered this; we keep it.

**Acceptance Scenarios**:

1. **When** the wizard runs with `--validity-hours 0`, **Then** it exits non-zero with a typed "validity hours must be positive" error.

---

## Functional Requirements

- **FR-1** `--validity-hours` is **optional** on `swap-wizard`, `disburse-wizard`, `withdraw-wizard`, and `swap-quote`. When absent, the wizard computes `validityUpperBoundSlot` from `Validity.queryUpperBoundSlot AutoLongest`. When present (positive), the wizard computes via `Validity.queryUpperBoundSlot (ExactlyHours N)`.
- **FR-2** The static `h == 0 || h > 168` guard is **deleted** in all three wizards. Only `h == 0 → reject` remains (User Story 4).
- **FR-3** `ResolverEnv` in each wizard exposes `reEnvComputeUpperBound :: ValidityChoice -> m (Either HorizonError SlotNo)` (or a wizard-local wrapper around the helper). `reEnvCurrentTip` is removed.
- **FR-4** `WizardEnv` carries `weUpperBoundSlot :: SlotNo` precomputed by the resolver. The pure translator no longer multiplies `tip * slotsPerHour`.
- **FR-5** Wizard answers' `wqValidityHours` becomes `Maybe Word16` (was `Word8`). Sentinel = `Nothing` = AutoLongest.
- **FR-6** `intent.json` schema is **unchanged**: it still carries `validityUpperBoundSlot` as a plain slot number. Only the way the wizard computes it changes.
- **FR-7** Wizard-side error type gains a constructor like `WizardValidityOvershoot HorizonError` that round-trips the four diagnostic fields from `cardano-node-clients`'s `HorizonError`.
- **FR-8** All four `Cli/*Wizard.hs` parsers make `--validity-hours HOURS` optional and drop the `1..168` help text.
- **FR-9** Unit fixtures: `test/fixtures/swap-wizard/env.json` (and equivalents for disburse, withdraw) replace `currentTip` with `upperBoundSlot`. Golden tests assert the rewritten contract.
- **FR-10** The cardano-node-clients pin in `cabal.project` is at or past `1dc1b87` (post-merge of [PR #134](https://github.com/lambdasistemi/cardano-node-clients/pull/134)).
- **FR-11** `docs/quickstart.md`, `docs/swap.md`, and `docs/withdraw.md` describe the new contract: omit for chain-default, set for explicit policy, overshoot errors loudly.
- **FR-12** `app/horizon-probe/Main.hs` ships as the live-boundary smoke artefact for reviewers; it stays callable but is not part of any test suite.

## Out of Scope

- Adding new validity *modes* (e.g. `MaxHours`, `--validity-slot`). The wizard surface stays binary: hours-or-omit.
- Re-running the full `pragma-org/amaru-treasury` bash parity comparison; the bash recipe's "+5 days when inside safe zone" extension is now subsumed by the helper's `AutoLongest`, so a separate parity audit isn't required by this ticket.
- A `MaxHours`-style clamp policy. The helper supports it, the CLI doesn't expose it yet — file a follow-up if needed.

## Success Criteria

- `nix develop -c just ci` green.
- Live `swap-wizard` with no `--validity-hours` produces a buildable tx end-to-end on mainnet.
- Live `swap-wizard --validity-hours 120` (mid-epoch) returns `WizardValidityOvershoot` at the wizard step, never invokes `tx-build`.
- Existing golden fixtures continue to round-trip after re-derivation, or the spec calls out the new golden values.

## Risks & Notes

- **Fixture churn.** `test/fixtures/swap-wizard/env.json` and `expected.intent.json` need re-derivation. The `validityUpperBoundSlot` in the golden intent was previously `186342942 + 6*3600 = 186364542`; after the rule change it becomes whatever the test feeds as `upperBoundSlot`. We make the fixture self-consistent by pinning `upperBoundSlot = 186364542` directly.
- **Bash parity gap.** The bash recipe's `compute_validity_period` uses `slotsToEpochEnd` and a hard-coded 5-day extension inside the safe zone; the helper uses a binary search over `slotToWallclock`. Both should arrive at the same slot mid-epoch (end-of-current-era). The `app/horizon-probe` output captured in #89's PR description provides a live cross-check.
- **Withdraw wizard.** Already uses `WithdrawResolverEnv` with `wreCurrentTip`. Same rewrite shape.
