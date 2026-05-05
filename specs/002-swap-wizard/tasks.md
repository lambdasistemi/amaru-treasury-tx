# Tasks: Swap Wizard

**Input**: Design documents from `/specs/002-swap-wizard/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/swap-wizard-cli.md](./contracts/swap-wizard-cli.md),
[contracts/network-constants.md](./contracts/network-constants.md),
[quickstart.md](./quickstart.md)

**Tests**: Required by Constitution V (golden CBOR fixtures) and
SC-002/SC-003. Each user-story phase contains its own tests.

**Organization**: tasks grouped by user story so each story is
independently implementable and testable. Reviewer reads on
[PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on
  unfinished tasks)
- **[Story]**: which user story (US1 / US2 / US3)
- File paths are absolute relative to repo root

## Path conventions

- New library module: `lib/Amaru/Treasury/Tx/SwapWizard.hs`
- Subcommand wiring: `app/amaru-treasury-tx/Main.hs`
- Tests: `test/unit/SwapWizardSpec.hs`
- Test fixtures: `test/fixtures/swap-wizard/`

The owning contract for any list reproduced below is the file in
brackets — see [data-model.md](./data-model.md) and
[contracts/swap-wizard-cli.md](./contracts/swap-wizard-cli.md).
Tasks reference the contract rather than duplicating fields.

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: cabal/justfile/flake plumbing for the new module +
fixtures.

- [ ] T001 Add `lib/Amaru/Treasury/Tx/SwapWizard.hs` and the new
      `Amaru.Treasury.Tx.SwapWizard` exposed module in
      `amaru-treasury-tx.cabal` (library stanza). Add `aeson-pretty`
      to `build-depends` if not already present. Confirm
      `cabal check` still passes.
- [ ] T002 [P] Add `test/unit/SwapWizardSpec.hs` to the
      `unit-tests` test-suite stanza in
      `amaru-treasury-tx.cabal`. Make sure `hspec-discover` picks
      it up.
- [ ] T003 [P] Add `test/fixtures/swap-wizard/` to
      `extra-source-files` in `amaru-treasury-tx.cabal`.
- [ ] T004 [P] Confirm `just ci` recipe still chains
      `build → unit → golden → format-check`; no recipe edit
      expected.

**Checkpoint**: package compiles with the new module skeleton; tests
discover the new spec; `just ci` is green on the empty module.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Types and pure scaffolding that every user story
consumes. Defined by [data-model.md](./data-model.md) §1–§3.

- [ ] T005 Implement the `Hex`, `Hex28` newtypes (validated
      28-byte-hex parser) in `lib/Amaru/Treasury/Tx/SwapWizard.hs`,
      plus their `FromJSON` / `ToJSON` instances. Shape per
      [data-model.md §1](./data-model.md).
- [ ] T006 Implement `SwapWizardQ`, `RationaleAnswers`, and
      `WizardError` in `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Field
      list and Haddock per [data-model.md §1
      and §3](./data-model.md). Strict, leading commas, fourmolu
      70-col.
- [ ] T007 Implement `WizardEnv`, `NetworkConstants`,
      `RegistryView`, `ScopeOwners`, `TreasuryRefs`, `ScopeView`,
      `TreasurySelection`, `WalletSelection` in
      `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Field list per
      [data-model.md §2](./data-model.md).
- [ ] T008 [P] Add a stable `ToJSON SwapIntentJSON` (and the
      nested record types) in
      `lib/Amaru/Treasury/Tx/SwapIntentJSON.hs` that mirrors the
      existing `FromJSON` field names. Pin key order to the record
      order. Reference [research R9](./research.md). Add roundtrip
      QuickCheck property scaffolding (`encode . parse ≡ id` on
      decoded values) in `test/unit/SwapIntentJSONSpec.hs`
      (file may not yet exist; create it).

**Checkpoint**: types compile; JSON roundtrip property holds on the
existing fixtures from `001-treasury-tx-cli`.

---

## Phase 3: User Story 2 — pure testable translation (Priority: P1) 🎯 MVP

> **Story label**: `[US2]` matches `spec.md` US2 ("Pure, testable
> translation from answers to JSON"). Implementing this MVP first
> earns the golden test that User Story 1 (produce valid
> `intent.json`) and User Story 3 (audit artifact preserved)
> consume.

**Goal**: `wizardToIntentJSON :: WizardEnv -> SwapWizardQ ->
Either WizardError SwapIntentJSON` is total, pure, and golden-tested.

**Independent test**: Load a fixture `WizardEnv` + `SwapWizardQ`,
run the translation, compare to a checked-in
`expected.intent.json`. Round-trip the result through
`decodeSwapIntent + translateIntent`.

**Test-first ordering** (Constitution V): fixtures + spec + golden
are authored *before* the implementation, and the spec must run RED
once before the implementation is written.

- [ ] T009 [P] [US2] Author fixtures
      `test/fixtures/swap-wizard/env.json` and
      `test/fixtures/swap-wizard/answers.json` for one realistic
      preprod-shaped scenario (Core scope, 50_000 ADA total,
      10_000 ADA chunk, rate 425000/1000000, 6 h validity,
      single-signer override). Encode shapes per
      [data-model.md §1, §2](./data-model.md) via the `FromJSON`
      instances landed in T005–T007.
- [ ] T010 [P] [US2] Author golden file
      `test/fixtures/swap-wizard/expected.intent.json` by hand,
      formatted with the stable encoder from T008.
- [ ] T011 [US2] Implement `test/unit/SwapWizardSpec.hs` with
      these `it` blocks; all must compile and run RED:
      - `"matches golden expected.intent.json"` — loads T009
        fixtures, runs `wizardToIntentJSON`, encodes with T008's
        stable encoder, compares to T010.
      - `"round-trips through decodeSwapIntent + translateIntent"`
        — feeds the encoded JSON to `decodeSwapIntent` then
        `translateIntent`, expects `Right`.
      - `"rejects WizardError cases"` — table-driven negative
        examples covering each `WizardError` constructor.
- [ ] T012 [US2] Confirm RED: run `cabal test unit-tests -O0
      --test-options=--match=SwapWizard` and observe the spec
      failing (no `wizardToIntentJSON` yet).
- [ ] T013 [US2] Implement the field-by-field translation
      `wizardToIntentJSON` in
      `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Mapping per the
      contract table in [data-model.md §4](./data-model.md). Each
      branch covered by a Haddock paragraph that names the source
      field.
- [ ] T014 [US2] Implement local validation that produces
      `WizardError`: chunk size positive, chunk size ≤ amount,
      validity hours in [1, 48], rate denominator non-zero, signer
      override hex-28 well-formed. Failure shapes per
      [data-model.md §3](./data-model.md).
- [ ] T014a [US2] Confirm GREEN: rerun the same `cabal test`
      command from T012; all three `it` blocks pass.
- [ ] T014b [US2] Run `just ci`; the new spec must remain green
      end-to-end.

**Checkpoint (MVP)**: `wizardToIntentJSON` is correct, golden-tested,
and round-trips. The wizard can be exercised purely from a fixture
without IO. SC-002 satisfied for the fixture path. spec.md's US2
acceptance scenarios are met.

---

## Phase 4: User Story 1 (Part A) — Provider-IO resolver (Priority: P1)

> **Story label**: `[US1]` matches `spec.md` US1 ("Produce a valid
> intent.json from a guided questionnaire"). The resolver is the
> first half of US1's deliverable; the CLI in Phase 5 is the second.

**Goal**: An IO function `resolveWizardEnv :: ResolverInput ->
Provider IO -> IO WizardEnv` that fills `WizardEnv` from a real
backend, plus the curated `NetworkConstants` table.

**Independent test**: against a stub `Provider IO` that returns
fixed UTxOs, registry view, and tip, the resolver produces a
`WizardEnv` byte-equal to the T011 fixture (modulo selection order
when ties).

- [ ] T015 [US1] Implement `networkConstants :: Network ->
      Either String NetworkConstants` in
      `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Mainnet + preprod
      rows. Each value carries a comment block citing its source:
      - SundaeSwap V3 order address: SundaeSwap V3 deployment
        notes (current at time of PR).
      - USDM policy/token: USDM docs.
      - `extraPerChunkLovelace`, `sundaeProtocolFeeLovelace`:
        values used in
        [`pragma-org/amaru-treasury/journal/2026/lib/swap_order.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/swap_order.sh)
        at the merge commit, with the link in the comment.
      - `slotsPerHour`: 3600 for 1-second slots on
        preprod/mainnet (Conway era).
      - `defaultPoolId`: ADA↔USDM pool id at the merge commit.
      Contract:
      [contracts/network-constants.md](./contracts/network-constants.md).
- [ ] T016 [US1] Add a unit test
      `test/unit/SwapWizardSpec.hs::networkConstants` that asserts
      both rows decode their `Addr` and `Hex28` fields without
      error.
- [ ] T017 [US1] Implement `ResolverInput` (network, wallet addr,
      registry NFT UTxO, scope, total ADA) in
      `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Plus `ResolverError`
      with constructors for: empty wallet UTxOs, empty treasury
      UTxOs, registry walk failure, network not supported,
      shortfall (Σ inputs < total), network mismatch on wallet
      address.
- [ ] T018 [US1] Implement the registry walk helper (uses the
      existing `Backend` typeclass from
      `lib/Amaru/Treasury/Backend.hs`) in
      `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Returns
      `RegistryView`. No new direct N2C dependency
      ([research R3](./research.md)).
- [ ] T019 [US1] Implement deterministic largest-first treasury
      UTxO selection
      ([research R4](./research.md)) and largest-pure-ADA wallet
      UTxO selection ([research R5](./research.md)) as pure
      helpers in `lib/Amaru/Treasury/Tx/SwapWizard.hs`. Selection
      functions take a `Map TxIn Value` so they are unit-testable
      without IO.
- [ ] T020 [P] [US1] QuickCheck property: largest-first selection
      yields `Σ inputs ≥ total` and `tsLeftoverLovelace = Σ inputs
      − total`, in `test/unit/SwapWizardSpec.hs`.
- [ ] T021 [US1] Implement `resolveWizardEnv :: Provider IO ->
      ResolverInput -> IO (Either ResolverError WizardEnv)`. The
      function is small: dispatch the four queries, project into
      the data-model types. No business logic beyond the
      selection helpers from T019.
- [ ] T022 [US1] Add a stub `Provider IO` (test helper) in
      `test/unit/SwapWizardSpec.hs` that returns the T009 fixture
      data. Test that `resolveWizardEnv` over it produces a
      `WizardEnv` whose `wizardToIntentJSON` against the T009
      answers matches T010's golden.
- [ ] T022a [US1] Add a negative test in
      `test/unit/SwapWizardSpec.hs`: stub `Provider IO` returns a
      wallet address whose `Network` does not match
      `ResolverInput.network`; assert
      `Left ResolverNetworkMismatch`. Covers the network-mismatch
      edge case from `spec.md`.

**Checkpoint**: resolver is wired, errors are typed, the IO path
is unit-tested against a stub. SC-004 satisfied.

---

## Phase 5: User Story 1 (Part B) + User Story 3 — CLI subcommand and audit (Priority: P1, audit P2)

> **Story labels**: `[US1]` (CLI is the deliverable of spec.md US1)
> and `[US3]` (audit-artifact constraints from spec.md US3 — no
> `runSwapBuild`, JSON file is the only audit trail).

**Goal**: `amaru-treasury-tx swap-wizard` runs the prompt loop +
resolver + pure translation + file write, never invokes
`runSwapBuild`. Contract:
[contracts/swap-wizard-cli.md](./contracts/swap-wizard-cli.md).

**Independent test**: integration test that exercises
`swap-wizard --yes` with all answers as flags against the stub
`Provider IO` and asserts the produced file equals T010's golden.

- [ ] T023 [US1] Add `Cmd.SwapWizard` parser to
      `app/amaru-treasury-tx/Main.hs`'s `optparse-applicative`
      tree. Flags exactly per
      [contracts/swap-wizard-cli.md §1](./contracts/swap-wizard-cli.md).
- [ ] T024 [US1] Implement the prompt loop helper (reads from
      stderr per [contract §3](./contracts/swap-wizard-cli.md)) in
      `app/amaru-treasury-tx/Main.hs`. Order is fixed per
      [contract §2](./contracts/swap-wizard-cli.md). Each missing
      flag triggers its prompt; when `--yes` is set, missing flags
      cause exit code 2.
- [ ] T025 [US1] Implement the resolved-env summary printer
      (verbose + pre-confirmation summary) in the same file.
      Output is human-readable, each field on its own line, on
      stderr (per FR-013 and contract §3).
- [ ] T026 [US1] Implement the confirmation prompt; on "no", exit 1.
      On `--yes`, skip and proceed.
- [ ] T027 [US3] Wire the file write: `--out PATH`, refuse to
      overwrite without `--force`, exit 5 if path exists. On
      `--dry-run`, write JSON to stdout and skip the file write.
      Audit: this task enforces that the JSON is the *only*
      side-effect — no transaction build, no signing, no submit.
- [ ] T028 [US1] Map `ResolverError` and `WizardError` to exit
      codes per
      [contract §4](./contracts/swap-wizard-cli.md). Format
      messages as `swap-wizard: <message>` on stderr.
- [ ] T029 [US1] Update `README.md` and `quickstart.md` with the
      `swap-wizard` invocation. Link from the README to
      [quickstart.md](./quickstart.md).
- [ ] T030 [US3] Integration test in
      `test/unit/SwapWizardSpec.hs`: drive the subcommand with
      flags-only inputs against the stub `Provider IO`, assert
      that the file written equals T010's golden byte-for-byte.
      Asserts the audit invariant: identical `WizardEnv` + answers
      produce identical JSON.

**Checkpoint**: end-to-end JSON producer behaves to spec, exit
codes match contract, audit trail (the JSON file) is preserved.
SC-001 + SC-003 satisfied for the stub backend.

---

## Phase 6: Polish and cross-cutting concerns

- [ ] T031 Run `just ci` (which runs build + unit + golden +
      format-check + hlint) plus `cabal check`; resolve any new
      warnings to keep the package Hackage-ready per Constitution
      VI.
- [ ] T032 Update PR #28 description with the final command-line
      reference and link to
      [quickstart.md](./quickstart.md).
- [ ] T033 Manual preprod E2E per
      [quickstart.md](./quickstart.md) §3: produce
      `intent.json` with the wizard, hand it to
      `amaru-treasury-tx swap`, confirm the existing swap golden
      harness still passes byte-for-byte. Record the run in the
      PR description.

**Checkpoint**: ready for review and merge once #28 is green.

---

## Dependencies

```
Setup (T001-T004)
    └── Foundational (T005-T008)
            └── Phase 3 [US2] pure translation (T009-T014b) ── MVP gate
                    └── Phase 4 [US1] resolver (T015-T022a) ── consumes wizardToIntentJSON
                            └── Phase 5 [US1]+[US3] CLI (T023-T030)
                                    └── Phase 6 polish (T031-T033)
```

Phase 3 (`[US2]` pure translation) is implemented first; it is the
MVP gate. Phase 4 (`[US1]` resolver) consumes
`wizardToIntentJSON`. Phase 5 (`[US1]` CLI + `[US3]` audit
constraint) wires both into the subcommand. Polish runs last.

## Parallel opportunities

Within Phase 1: T002, T003, T004 are independent; cabal edit T001
must land first.

Within Phase 2: T008 (`[P]`) lives in a different module than
T005-T007.

Within Phase 3: T009 (`[P]`) and T010 (`[P]`) are file-only fixtures
authored before any implementation per the test-first requirement.

Within Phase 4: T020 (`[P]`) is a property test independent of T021's
IO glue.

## MVP scope

**MVP = Phase 1 + Phase 2 + Phase 3.** Proves the typed translation
matches the existing JSON contract and earns the golden test.
Phase 4 and Phase 5 land on top to make the wizard usable from the
CLI; Phase 6 closes out review.
