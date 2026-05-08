# Tasks: Disburse Amount Includes Swap-Order Overhead

**Input**: Approved spec at [`specs/008-disburse-includes-overhead/spec.md`](./spec.md)

**Tracking issue**: [#68](https://github.com/lambdasistemi/amaru-treasury-tx/issues/68)

**Tracking PR**: [#69](https://github.com/lambdasistemi/amaru-treasury-tx/pull/69)

**Scope reminder** (from spec): the disburse redeemer's `amount`, the
treasury input selection target, the treasury leftover output, and the
under-funding shortfall check MUST all include
`N × extraPerChunkLovelace` (FR-001, FR-002, FR-006, FR-009).
`extraPerChunkLovelace` is the single funding source from the swap
intent — it MUST NOT be summed with `sundaeProtocolFeeLovelace` again.

**Tests**: each P1 story phase contains its own test tasks, written to
FAIL before the implementation that satisfies them, per Constitution V
(golden CBOR fixtures) and SC-001 / SC-002 / SC-003 / SC-004.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on
  unfinished tasks)
- **[Story]**: which user story (US1 / US2)
- File paths are absolute relative to repo root

## Path conventions

- Builder: `lib/Amaru/Treasury/Tx/SwapWizard.hs` (intent producer) and
  `lib/Amaru/Treasury/IntentJSON.hs` (JSON → typed `SwapIntent`
  translator, including the four sites named in FR-006).
- Bash recipe (US2): `pragma-org/amaru-treasury` repo,
  `journal/2026/bin/swap.sh` (out-of-tree; mirror task tracked
  separately).
- Unit specs: `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`,
  `test/unit/Amaru/Treasury/Tx/SwapSpec.hs`.
- Golden specs: `test/golden/SwapGoldenSpec.hs` (existing); new ADA
  swap fixtures under `test/fixtures/swap/` mirror current layout.

---

## Phase 1: Pre-implementation research

**Purpose**: clear FR-007 before touching code.

- [x] T001 [US1] Confirm the `Disburse { amount }` arm of
      `TreasurySpendRedeemer` in
      [`pragma-org/amaru-treasury` `validators/permissions.ak`](https://github.com/pragma-org/amaru-treasury/blob/main/validators/permissions.ak)
      does **not** constrain `amount` magnitude beyond signer approval
      (i.e. raising `amount` by `N × extraPerChunkLovelace` does not
      break the multisig check). Record the finding inline in
      `spec.md` under Assumptions; if the multisig DOES inspect
      magnitude, reopen the spec and stop.
      **Verified** at `pragma-org/amaru-treasury` sha
      `15817e6bcd6da7121f93022508572784af94a270` (origin/main,
      2026-05-08): the `Disburse { .. }` branch of the `withdraw`
      validator (`validators/permissions.ak:59`) uses `{ .. }`
      pattern — no field is extracted — and dispatches to
      `approved_by_owner_and_someone_else`, a pure multisig check.
      No `amount` comparison is performed in `permissions.ak`.
      Finding recorded in `spec.md` Assumptions section.

**Checkpoint**: FR-007 resolved; safe to proceed.

---

## Phase 2: User Story 1 — Haskell builder fix (P1)

**Purpose**: deliver SC-001, SC-002, SC-003 — the core fix.

### Failing tests first

- [ ] T002 [P] [US1] Add a unit test in
      `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` that asserts
      FR-001: for any `--split N ≥ 1`, the produced
      `siRedeemerAmountLovelace` equals
      `chunk_total + N × extraPerChunkLovelace` (parameterised on the
      intent's `extraPerChunkLovelace` value, not a literal). Use
      `N ∈ {1, 12}` to cover the no-split and the issue's captured
      case. Test MUST fail against current `main`.
- [ ] T003 [P] [US1] Add a unit test that asserts FR-002:
      `siTreasuryLeftoverLovelace` shrinks by exactly
      `N × extraPerChunkLovelace` compared to today's behaviour,
      holding `chunk_total` constant. Test MUST fail against current
      `main`.
- [ ] T004 [P] [US1] Add a unit test that asserts FR-009: when the
      treasury UTxO cannot fund
      `chunk_total + N × extraPerChunkLovelace`, the build fails at
      construction time with a clear shortfall error message. Test
      MUST fail against current `main` (today the shortcoming would
      manifest at submit time, not build time).
- [ ] T005 [US1] Add / update an ADA-swap golden under
      `test/golden/SwapGoldenSpec.hs` keyed off the issue's captured
      example (`30af3b92…`, `--usdm 100000 --split 12`, mainnet,
      1,450,000 ADA treasury UTxO + 100 ADA wallet UTxO) so the
      resulting CBOR / decoded view shows: operator wallet net spend
      on success ≈ tx fee only; treasury leftover smaller by
      `12 × extraPerChunkLovelace`; redeemer `amount` equals
      `chunk_total + 12 × extraPerChunkLovelace` (SC-001, SC-002,
      acceptance scenario US1#1). Golden MUST fail against current
      `main`; the post-fix expected fixture is committed alongside
      the implementation in T006.

### Implementation

- [ ] T006 [US1] Implement the four-site fix in the Haskell builder
      (FR-001, FR-002, FR-006, FR-009). All four computations MUST
      derive `N × extraPerChunkLovelace` from the same
      `swiExtraPerChunkLovelace`-fed source already in the intent.
      Concretely:

      1. **Redeemer amount** — at the
         `siRedeemerAmountLovelace = Coin (swiAmountLovelace sw)`
         site (`lib/Amaru/Treasury/IntentJSON.hs`, around the
         `mkChunks` call), set it to
         `Coin (swiAmountLovelace sw + N * swiExtraPerChunkLovelace sw)`
         where `N = length chunks`.
      2. **Treasury input selection target** — wherever the swap
         wizard picks treasury UTxOs to spend, raise the target by
         the same `N × extraPerChunkLovelace` so a UTxO that just
         covered the swap today still covers it after the fix.
      3. **Treasury leftover output** — recompute
         `siTreasuryLeftoverLovelace` so the value invariant
         `treasury inputs = redeemer amount + leftover` holds with
         the new redeemer amount.
      4. **Under-funding shortfall check** — extend the
         build-time validation so it raises a clear error when
         treasury inputs cannot cover
         `chunk_total + N × extraPerChunkLovelace`.

      Keep `sundaeProtocolFeeLovelace` exactly where it is
      today (written into each Sundae order datum); do **not** add
      it to the funding overhead.

- [ ] T007 [US1] Update / commit any expected golden CBOR / JSON
      fixtures changed by T006. Run `nix develop -c just ci` and
      confirm green.

**Checkpoint**: US1 acceptance scenarios 1–3 pass; SC-001, SC-002,
SC-003 met; existing test suite green.

---

## Phase 3: User Story 2 — Bash recipe mirror (P2)

**Purpose**: SC-004 — `swap.sh` agrees byte-for-byte with the Haskell
CLI for the same inputs.

- [ ] T008 [US2] Open a follow-up PR against
      [`pragma-org/amaru-treasury`](https://github.com/pragma-org/amaru-treasury)
      that updates `journal/2026/bin/swap.sh` to mirror T006: the
      bash-built disburse redeemer must include
      `N * extraPerChunkLovelace` taken from the swap intent
      (`networkConstants.extraPerChunkLovelace`), not from a parallel
      hard-coded constant, and the leftover/treasury-input selection
      math must match the Haskell builder.
- [ ] T009 [US2] Add a regression test (in this repo) that proves
      SC-004 unconditionally: check in a recipe-generated fixture
      under `test/fixtures/swap/bash-parity/` containing the disburse
      redeemer (and its `amount`) produced by `swap.sh` for a
      well-defined intent input, then have the Haskell-CLI output for
      the same intent compared byte-for-byte against that fixture.
      The fixture is regenerated by an explicit
      `just regen-bash-parity-fixture` recipe (which DOES require the
      external `pragma-org/amaru-treasury` checkout and is the sole
      place that depends on it); the test itself runs against the
      checked-in fixture and never skips. Refresh the fixture as part
      of T008 once the bash recipe is updated.

**Checkpoint**: SC-004 met; the journal recipe and the Haskell CLI
agree.

---

## Phase 4: Verification

- [ ] T010 Reproduce issue #68's captured example (`--usdm 100000
      --split 12`, mainnet, 1,450,000 ADA treasury UTxO + 100 ADA
      wallet UTxO) inside this repo using `tx-build`'s offline
      evaluation path: build the transaction body from the new
      builder against a fixture environment (no live submission),
      compare the wallet net spend, treasury leftover, and disburse
      redeemer `amount` against SC-001 / SC-002 expectations, and
      record the resulting transaction body hash plus the
      script-evaluation evidence (Plutus log / cost) in the PR
      description as the developer-owned proof. SC-003 is satisfied
      structurally by T005's golden against `equal_plus_min_ada`; no
      live submission is required for the PR gate. **Optional, gated
      on operator acceptance**: an out-of-band live mainnet
      submission of the same scenario by a treasury operator, with
      its tx hash appended to the PR description if performed; this
      is explicitly NOT a gate for merging the Haskell change.
