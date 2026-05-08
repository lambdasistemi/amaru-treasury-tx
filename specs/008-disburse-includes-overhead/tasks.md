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

- [x] T002 [P] [US1] Add a unit test in
      `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` that asserts
      FR-001: for any `--split N ≥ 1`, the produced
      `siRedeemerAmountLovelace` equals
      `chunk_total + N × extraPerChunkLovelace` (parameterised on the
      intent's `extraPerChunkLovelace` value, not a literal). Use
      `N ∈ {1, 12}` to cover the no-split and the issue's captured
      case. Test MUST fail against current `main`.
- [x] T003 [P] [US1] Add a unit test that asserts FR-002:
      `siTreasuryLeftoverLovelace` shrinks by exactly
      `N × extraPerChunkLovelace` compared to today's behaviour,
      holding `chunk_total` constant. Test MUST fail against current
      `main`.
- [x] T004 [P] [US1] Add a unit test that asserts FR-009: when the
      treasury UTxO cannot fund
      `chunk_total + N × extraPerChunkLovelace`, the build fails at
      construction time with a clear shortfall error message. Test
      MUST fail against current `main` (today the shortcoming would
      manifest at submit time, not build time).
- [x] T005 [US1] Pin the issue's captured example
      (`--usdm 100000 --split 12`, mainnet,
      1,450,000 ADA treasury UTxO, 100 ADA wallet UTxO) in
      `test/red/Amaru/Treasury/Tx/SwapWizardRedSpec.hs` (the
      `red-tests` bucket established in T002, so the failing
      assertions are executable today and the default review
      gate stays green). The cases run the full
      `resolveWizardEnv → wizardToTreasuryIntent → translateIntent SSwap`
      pipeline and assert the SC-001 / SC-002 surface on the
      resulting typed `SwapIntent`:

      1. `length (siSwapOrders si) == 12` — N matches the spec
         scenario.
      2. `siRedeemerAmountLovelace == chunk_total + 12 * extraPerChunkLovelace`
         (FR-001) — derived from `siSwapOrderExtraLovelace`,
         no test-local literal overhead.
      3. `siTreasuryLeftoverLovelace == 1_005_516_195_556`
         lovelace (the spec's `1,005,555.555556 − 12 × 3.28 =
         1,005,516.195556 ADA`, FR-002 / SC-001).
      4. `chunk_total + N * siSwapOrderExtraLovelace +
         siTreasuryLeftoverLovelace == treasury_input` — the
         algebraic restatement of FR-003 / SC-001 that catches
         the bug. The simpler `siRedeemerAmountLovelace +
         siTreasuryLeftoverLovelace == treasury_input`
         formulation is *not* a red proof: it already holds
         today because the buggy redeemer is too small by
         `N * extra` and the buggy leftover is too big by
         `N * extra`, so they cancel. The on-chain value
         flow each swap-order output actually carries is
         `chunk + extra`, so the treasury must cover
         `chunk_total + N * extra + leftover` for the
         operator wallet's net spend to be the tx fee only.

      A CBOR-level snapshot of the resulting tx body is left
      to T006 (where the implementation produces the byte
      output that any byte-identity golden would have to
      compare against; checking in a hand-crafted
      `expected.cbor` ahead of T006 would either be
      pendingWith — the shape rejected for T002 — or a
      duplicate of T006's snapshot).

      The three amount assertions (2, 3, 4) MUST fail against
      current `main`; the chunk-count assertion (1) anchors
      the scenario and passes today (the wizard already
      produces 12 chunks for the issue inputs — only the
      amounts are wrong).

### Implementation

- [x] T006 [US1] Implement the four-site fix in the Haskell builder
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

- [x] T007 [US1] Update / commit any expected golden CBOR / JSON
      fixtures changed by T006. Run `nix develop -c just ci` and
      confirm green. **Folded into T006** so the slice stays
      bisect-safe: the production fix and the matching fixture
      refresh (`test/fixtures/swap-wizard/env.json`,
      `test/fixtures/swap-wizard/expected.intent.json`,
      `test/fixtures/swap/intent.json`,
      `test/fixtures/swap/expected.cbor`,
      `test/fixtures/swap/target.tx.json`,
      `test/fixtures/swap/provenance.md`,
      `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`,
      `test/red/Amaru/Treasury/Tx/SwapWizardRedSpec.hs`,
      `test/golden/SwapGoldenSpec.hs`'s `UPDATE_GOLDENS`
      knob) all land in a single gate-green commit.

**Checkpoint**: US1 acceptance scenarios 1–3 pass; SC-001, SC-002,
SC-003 met; existing test suite green.

---

## Phase 3: User Story 2 — Bash recipe mirror (P2)

**Purpose**: SC-004 — `swap.sh` agrees byte-for-byte with the Haskell
CLI for the same inputs.

- [ ] T008 [US2] **Follow-up PR — out of scope for this PR**: open
      a PR against
      [`pragma-org/amaru-treasury`](https://github.com/pragma-org/amaru-treasury)
      that updates `journal/2026/bin/swap.sh` to mirror T006: the
      bash-built disburse redeemer must include
      `N * extraPerChunkLovelace` taken from the swap intent
      (`networkConstants.extraPerChunkLovelace`), not from a parallel
      hard-coded constant, and the leftover/treasury-input selection
      math must match the Haskell builder. Until T008 lands,
      `test/fixtures/swap/target.tx.json` in this repo is the
      Haskell-side target the bash recipe must converge on (see
      `test/fixtures/swap/provenance.md` for the post-T006 / pre-T008
      state).
- [ ] T009 [US2] **Deferred to T008's PR**: add the SC-004 byte-parity
      regression test (in this repo) that compares the Haskell-CLI
      output byte-for-byte against the bash-recipe-produced fixture
      under `test/fixtures/swap/bash-parity/`, with `just
      regen-bash-parity-fixture` as the sole place that depends on
      the external checkout. The fixture cannot exist before T008
      regenerates the bash output, so this lands in the same change
      that closes T008 (or a closely-following PR once T008 merges).

**Checkpoint**: SC-004 is **not** met in this PR. The journal recipe
under `pragma-org/amaru-treasury` is unchanged and still produces the
pre-T006 disburse redeemer; the byte-for-byte agreement between the
bash recipe and the Haskell CLI is therefore broken. Restoring SC-004
is the goal of T008 (bash recipe update) followed by T009 (the
in-repo SC-004 byte-parity regression test). The only thing this PR
delivers on the Phase-3 surface is the Haskell-side post-fix target
in `test/fixtures/swap/target.tx.json` — the bytes the bash recipe
will need to converge on.

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
      description as the developer-owned proof.

      **In-repo numerical comparison — done in this PR**:
      `cabal test red-tests` exercises this exact scenario via
      the `SC-001 / issue #68 reproduction` describe block in
      `test/red/Amaru/Treasury/Tx/SwapWizardRedSpec.hs`, which
      asserts `length (siSwapOrders si) == 12`,
      `siRedeemerAmountLovelace == chunk_total + 12 *
      siSwapOrderExtraLovelace`,
      `siTreasuryLeftoverLovelace == 1_005_516_195_556` lovelace
      (the spec's `1,005,516.195556 ADA`), and the on-chain
      value-balance `chunk_total + 12 *
      siSwapOrderExtraLovelace + siTreasuryLeftoverLovelace ==
      1_450_000_000_000` against a treasury input of 1,450,000
      ADA. The byte-identity gate for the same shape is the
      `swap golden` in `test/golden/SwapGoldenSpec.hs` against
      `target.tx.json` (post-T006 Haskell target; bash-side
      parity restored later by T008 / T009). SC-003 is satisfied
      structurally by the on-chain `equal_plus_min_ada`
      invariant — increasing `amount` only loosens the
      validator's leftover constraint.

      **Pending PR finalization**: the tx body hash and the
      Plutus-script evaluation evidence (memory / steps / log)
      from running `runFromIntent` against the post-fix intent
      are still to be recorded in the PR description by the
      reviewer at finalization time. T010 stays unchecked
      until that evidence lands in the PR body alongside the
      reviewer-owned approval.

      **Optional, gated on operator acceptance**: an out-of-band
      live mainnet submission of the same scenario by a treasury
      operator, with its tx hash appended to the PR description
      if performed; this is explicitly NOT a gate for merging
      the Haskell change.
