# Tasks: Disburse Wizard

**Input**: Design documents from [`specs/004-disburse-wizard/`](.)
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/disburse-wizard-cli.md](./contracts/disburse-wizard-cli.md),
[contracts/disburse-cli.md](./contracts/disburse-cli.md),
[contracts/disburse-intent-json.md](./contracts/disburse-intent-json.md),
[quickstart.md](./quickstart.md)

**Tracking issue**: [#44](https://github.com/lambdasistemi/amaru-treasury-tx/issues/44)

**Tests**: Required by Constitution V (golden CBOR fixtures) and
SC-003 / SC-004. Each user-story phase contains its own tests, written
to FAIL before the implementation that satisfies them.

**Organization**: tasks grouped by user story so each story is
independently implementable and testable. The MVP gate is Phase 3
(pure translation, US3); the ADA + USDM body-CBOR goldens land in
Phases 4 and 5.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on
  unfinished tasks)
- **[Story]**: which user story (US1 / US2 / US3 / US4 / US5)
- File paths are absolute relative to repo root
- The owning contract for any list reproduced below is the file in
  brackets — see [data-model.md](./data-model.md),
  [contracts/disburse-wizard-cli.md](./contracts/disburse-wizard-cli.md),
  [contracts/disburse-cli.md](./contracts/disburse-cli.md), and
  [contracts/disburse-intent-json.md](./contracts/disburse-intent-json.md).
  Tasks reference the contract rather than duplicating fields.

## Path conventions

- Library modules: `lib/Amaru/Treasury/Tx/{DisburseIntentJSON,DisburseBuild,DisburseWizard}.hs`
- Trace modules: `lib/Amaru/Treasury/Tx/Disburse/Trace.hs`,
  `lib/Amaru/Treasury/Tx/DisburseWizard/Trace.hs`
- Subcommand wiring: `app/amaru-treasury-tx/Main.hs`
- Unit specs: `test/unit/Amaru/Treasury/Tx/Disburse{,Build,Wizard}Spec.hs`
- Golden specs: `test/golden/Amaru/Treasury/Tx/{AdaDisburse,UsdmDisburse}GoldenSpec.hs`
  (the `Golden` suffix disambiguates from the unit `DisburseSpec` —
  cabal would technically resolve same-named modules across
  `hs-source-dirs`, but the convention in this repo follows
  [`SwapGoldenSpec.hs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/golden/SwapGoldenSpec.hs))
- Wizard fixtures: `test/fixtures/disburse-wizard/`
- Build fixtures: `test/fixtures/disburse/{ada,usdm}/`

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: cabal/justfile/flake plumbing for the new modules + fixtures.

- [ ] T001 Add the five new modules
      (`Amaru.Treasury.Tx.DisburseIntentJSON`,
      `Amaru.Treasury.Tx.DisburseBuild`,
      `Amaru.Treasury.Tx.DisburseWizard`,
      `Amaru.Treasury.Tx.Disburse.Trace`,
      `Amaru.Treasury.Tx.DisburseWizard.Trace`) to the library
      `exposed-modules` list in `amaru-treasury-tx.cabal`. Verify
      `aeson-pretty` is already in `build-depends` (added in 002); add
      it if missing. Confirm `just format-check` and `just hlint`
      recipes exist in the `justfile`; add them if missing (they
      are referenced by `just ci`). Run `nix develop -c just
      cabal-check` and confirm pass.
- [ ] T002 [P] Add the new unit specs
      (`Amaru.Treasury.Tx.DisburseSpec`,
      `Amaru.Treasury.Tx.DisburseBuildSpec`,
      `Amaru.Treasury.Tx.DisburseWizardSpec`) to the `unit-tests`
      stanza's `other-modules` in `amaru-treasury-tx.cabal`, and the
      golden specs (`Amaru.Treasury.Tx.AdaDisburseGoldenSpec` and
      `Amaru.Treasury.Tx.UsdmDisburseGoldenSpec` under
      `test/golden/Amaru/Treasury/Tx/`) to the `golden-tests` stanza.
      The `Golden` suffix on the golden modules deliberately
      disambiguates from the unit `DisburseSpec`. Run `nix develop -c
      just build` and confirm both test suites compile (empty modules
      OK at this stage).
- [ ] T003 [P] Add the wizard and build fixture directories
      (`test/fixtures/disburse-wizard/`, `test/fixtures/disburse/`)
      to `extra-source-files` in `amaru-treasury-tx.cabal`.
- [ ] T004 [P] Confirm `just ci` recipe still chains `build → unit
      → golden → format-check → hlint → cabal-check`; no recipe edit
      expected.

**Checkpoint**: package compiles with the new (empty) module
skeletons; both test suites discover the new specs; `just ci` is
green.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Pure types and JSON-contract scaffolding that every user
story consumes. Defined by [data-model.md](./data-model.md) §1–§6
and [contracts/disburse-intent-json.md](./contracts/disburse-intent-json.md).

- [ ] T005 Implement `DisburseAnswers`, `RationaleAnswers`, and
      `DisburseError` in `lib/Amaru/Treasury/Tx/DisburseWizard.hs`.
      Field list and Haddock per [data-model.md §1
      and §3](./data-model.md). Strict, leading commas, fourmolu
      70-col, explicit export list.
- [ ] T006 [P] Implement `DisburseEnv`, `TreasurySelection` (with
      `tsInputValues`, `tsLeftoverLovelace`, `tsLeftoverUsdm`,
      `tsLeftoverOtherAssets`), and `WalletSelection` in
      `lib/Amaru/Treasury/Tx/DisburseWizard.hs`. Re-export
      `NetworkConstants`, `RegistryView`, `ScopeOwners`,
      `TreasuryRefs`, `ScopeView` from `Amaru.Treasury.Tx.SwapWizard`
      via the new module so downstream callers do not need to import
      from the swap module directly.
- [ ] T007 [P] Implement `DisburseIntentJSON`, `WalletJSON`,
      `ScopeJSON`, `DisburseJSON`, `SignersJSON`, and `RationaleJSON`
      in `lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs`. Field list per
      [data-model.md §4](./data-model.md). `FromJSON` + `ToJSON` with
      stable key order matching the record source order
      ([research R9](./research.md#r9-stable-json-encoder-for-goldens)).
      Add `encodeDisburseIntent :: DisburseIntentJSON ->
      ByteString.Lazy` using the same `aeson-pretty`-based stable
      encoder as `SwapIntentJSON.encodeIntentJSON`.
- [ ] T008 Extend `Amaru.Treasury.Tx.Disburse` with the
      `DisburseIntent` ADT split per
      [data-model.md §5](./data-model.md): `DisburseAdaIntent
      DisburseIntentFields Coin` and `DisburseUsdmIntent
      DisburseIntentFields Integer`. Refactor the existing
      `disburseAdaProgram` to consume `DisburseAdaIntent`. Keep this
      a *type-only* refactor — no behaviour change; the existing
      `Disburse.hs` body shape stays bit-identical.
- [ ] T009 [P] Implement `decodeDisburseIntent :: ByteString.Lazy ->
      Either String DisburseIntentJSON` and `translateDisburseIntent
      :: DisburseIntentJSON -> Either String TranslatedDisburseIntent`
      in `lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs`. Mapping table
      per [data-model.md §7.2](./data-model.md). The `usdm` branch
      reads `disburse.amount` as USDM smallest-units; the `ada`
      branch reads it as lovelace.
- [ ] T010 Implement the `Trace` type
      `Amaru.Treasury.Tx.DisburseWizard.Trace.WizardEvent` (constructor
      list per
      [contracts/disburse-wizard-cli.md §5](./contracts/disburse-wizard-cli.md))
      with the `eventTracer :: Tracer IO Text -> Tracer IO WizardEvent`
      wrapper, mirroring `Tx.SwapWizard.Trace.eventTracer`.
- [ ] T011 [P] Implement
      `Amaru.Treasury.Tx.Disburse.Trace.DisburseEvent` (constructor
      list per
      [contracts/disburse-cli.md §5](./contracts/disburse-cli.md))
      with the `disburseEventTracer` wrapper, mirroring
      `Tx.Swap.Trace.swapEventTracer`.
- [ ] T012 [P] Add a JSON round-trip QuickCheck property in
      `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs`: for any small
      generator over `DisburseIntentJSON`, the output of
      `decodeDisburseIntent . encodeDisburseIntent` must equal the
      input (modulo deterministic key ordering). Property uses a tiny
      generator constrained to the `usdm` and `ada` branches.
- [ ] T013 Confirm GREEN on Phase 2: `nix develop -c just unit`
      passes the round-trip property; `just cabal-check` clean.

**Checkpoint**: types compile; JSON round-trip property holds; both
trace types print to stderr in the expected shape via a smoke
helper.

---

## Phase 3: User Story 3 — pure testable translation (Priority: P1) 🎯 MVP

> **Story label**: `[US3]` matches `spec.md` US3 ("Pure, testable
> translation from answers to JSON"). Implementing this MVP first
> earns the golden test that User Story 1 (ADA disburse) and User
> Story 2 (USDM disburse) consume.

**Goal**: `disburseToIntentJSON :: DisburseEnv -> DisburseAnswers ->
Either DisburseError DisburseIntentJSON` is total, pure, and
golden-tested for both `--unit ada` and `--unit usdm`.

**Independent test**: Load fixture `(DisburseEnv, DisburseAnswers)`
pairs (one ADA, one USDM), run the translation, compare to checked-in
`expected.intent.ada.json` and `expected.intent.usdm.json`. Round-trip
each result through `decodeDisburseIntent + translateDisburseIntent`.

**Test-first ordering** (Constitution V): fixtures + spec + golden are
authored *before* the translation, and the spec must run RED once
before the implementation is written.

- [ ] T014 [P] [US3] Author fixture
      `test/fixtures/disburse-wizard/env.ada.json` for an
      ADA-disburse scenario (`core_development` scope, single treasury
      UTxO holding 1500 ADA, wallet UTxO holding 50 ADA, mainnet
      registry refs). Encoded shape matches the `FromJSON` for
      `DisburseEnv` landed in T006.
- [ ] T015 [P] [US3] Author fixture
      `test/fixtures/disburse-wizard/answers.ada.json`
      (50 ADA disburse, 6 h validity, single extra-signer
      `ops_and_use_cases`).
- [ ] T016 [P] [US3] Author fixture
      `test/fixtures/disburse-wizard/env.usdm.json` for a
      USDM-disburse scenario (`network_compliance` scope, single
      treasury UTxO holding 100 ADA + 500 USDM, wallet UTxO holding
      50 ADA, mainnet registry refs).
- [ ] T017 [P] [US3] Author fixture
      `test/fixtures/disburse-wizard/answers.usdm.json` (100 USDM
      disburse, 6 h validity, single extra-signer `core_development`).
- [ ] T018 [P] [US3] Author golden file
      `test/fixtures/disburse-wizard/expected.intent.ada.json` by
      hand, formatted with the stable encoder from T007. Field values
      derived from the contract table in
      [data-model.md §7.1](./data-model.md).
- [ ] T019 [P] [US3] Author golden file
      `test/fixtures/disburse-wizard/expected.intent.usdm.json` the
      same way.
- [ ] T020 [US3] Implement
      `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs` with these `it`
      blocks; all must compile and run RED:
      - `"matches golden expected.intent.ada.json"`
      - `"matches golden expected.intent.usdm.json"`
      - `"round-trips through decodeDisburseIntent + translateDisburseIntent"`
        (per fixture)
      - `"rejects DisburseError cases"` — table-driven negative
        examples covering each `DisburseError` constructor.
- [ ] T021 [US3] Confirm RED: run `nix develop -c just unit
      --test-options=--match=Disburse` and observe the spec failing
      (no `disburseToIntentJSON` yet).
- [ ] T022 [US3] Implement the field-by-field translation
      `disburseToIntentJSON` in
      `lib/Amaru/Treasury/Tx/DisburseWizard.hs`. Mapping per the
      contract table in [data-model.md §7.1](./data-model.md). Each
      branch (`ada`, `usdm`) covered by a Haddock paragraph naming
      its source field. **Pure** — no IO, no `Reader`, no chain
      queries.
- [ ] T023 [US3] Implement local validation that produces
      `DisburseError`: amount positive; validity-hours in [1, 48];
      extra-signer tokens are known scopes or hex-28 keyhashes; for
      `--unit usdm`, the `DisburseEnv`'s `tsLeftoverUsdm + amount`
      must equal `Σ USDM on inputs`. Failure shapes per
      [data-model.md §3](./data-model.md).
- [ ] T024 [US3] Confirm GREEN: rerun the same `cabal test` command
      from T021; all four `it` blocks pass. Run `just ci`; the spec
      must remain green end-to-end.

**Checkpoint (MVP)**: `disburseToIntentJSON` is correct,
golden-tested for both units, round-trips. The wizard can be
exercised purely from a fixture without IO. SC-003 + SC-004
satisfied for the fixture path. `spec.md`'s US3 acceptance scenarios
are met.

---

## Phase 4: User Story 1 — ADA disburse Provider-IO + golden (Priority: P1)

> **Story label**: `[US1]` matches `spec.md` US1 ("Produce a valid
> ADA disburse intent.json from a guided questionnaire").

**Goal**: A fully-resolved `DisburseEnv` produced by an IO resolver
against a real `Provider IO`, plus the body-CBOR golden for an ADA
disburse rebuilt against `/code/cardano-mainnet/ipc/node.socket`.

**Independent test**: Run
`amaru-treasury-tx --node-socket … disburse-wizard --unit ada …` end
to end against the local mainnet node; the resulting JSON must satisfy
the byte-CBOR golden under `test/fixtures/disburse/ada/body.cbor`
after running the build subcommand.

- [ ] T025 [US1] Implement `ResolverInput`, `ResolverEnv`,
      `ResolverError`, and `resolveDisburseEnv :: ResolverEnv IO ->
      ResolverInput -> IO (Either ResolverError DisburseEnv)` in
      `lib/Amaru/Treasury/Tx/DisburseWizard.hs`. Resolver dispatches
      the four `Provider IO` queries from
      [research R3](./research.md#r3-provider-io-surface-used-resolver),
      runs `verifyRegistry` + `registryViewFromVerified`, applies the
      selection helpers, and projects into the data-model types. No
      business logic beyond that.
- [ ] T026 [US1] Implement deterministic largest-first treasury UTxO
      selection by **lovelace** ([research R4](./research.md#r4-treasury-utxo-selection--ada-vs-usdm))
      in `lib/Amaru/Treasury/Tx/DisburseWizard.hs`. Selection function
      takes `[(TxIn, MaryValue)]` so it is unit-testable without IO.
- [ ] T027 [P] [US1] QuickCheck property in
      `test/unit/Amaru/Treasury/Tx/DisburseWizardSpec.hs`:
      largest-first selection by lovelace yields `Σ inputs ≥ amount`
      and `tsLeftoverLovelace = Σ inputs − amount`; leftover preserves
      every other asset present on the inputs verbatim.
- [ ] T028 [US1] Implement `runDisburseBuild :: ChainContext ->
      DisburseBuildInputs -> IO DisburseBuildResult` in
      `lib/Amaru/Treasury/Tx/DisburseBuild.hs`. Body shape mirrors
      [`runSwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs):
      load pparams, build via `disburseAdaProgram`, balance,
      re-evaluate per-redeemer ExUnits, return `DisburseBuildResult`.
      On any redeemer re-evaluation failure, emit `ScriptResult …
      (Left err)` for that index but continue producing a complete
      `DisburseBuildResult` (CBOR + fee + collateral). The runner in
      `Main.hs` (T048) is responsible for translating any `Left` into
      a non-zero exit code per FR-011 — `runDisburseBuild` itself
      does not throw on script failure. The `ChainContext` and
      `ScriptResult` types are imported unchanged from existing
      modules
      ([research R11](./research.md#r11-reusing-runswapbuilds-chaincontext)).
- [ ] T029 [P] [US1] Author ADA body-CBOR fixture set under
      `test/fixtures/disburse/ada/`: `intent.json` (the same one
      `expected.intent.ada.json` produces; T018 is the wizard view,
      this is the consumer view), `utxos.json` (synthesized
      `(TxIn, TxOut)` set covering the four reference inputs +
      treasury inputs + wallet UTxO), and `pparams.json`
      (already-checked-in fixture under
      [`test/fixtures/pparams.json`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/fixtures/pparams.json) — symlink).
- [ ] T030 [US1] Author
      `test/golden/Amaru/Treasury/Tx/AdaDisburseGoldenSpec.hs` with
      one `it` block: `"ada-disburse golden body matches"`.
      Loads T029 fixtures, calls a small fixture-recorder helper
      `runDisburseBuildFromFixtures` that builds a `ChainContext`
      from the `utxos.json` + `pparams.json` fixtures (no
      `Provider IO`, no node socket) and invokes `runDisburseBuild`
      directly. Strips ExUnits, compares the body bytes to
      `test/fixtures/disburse/ada/body.cbor`.
      Note: this is the same fixture-mode shape the swap golden
      uses; the helper itself lives in
      `test/golden/Amaru/Treasury/Tx/Fixture.hs` so both the ADA and
      USDM goldens share it.
- [ ] T031 [US1] Confirm RED: run `nix develop -c just golden
      --test-options=--match=ada-disburse` and observe the spec
      failing (no `body.cbor` yet, or no `runDisburseBuild`).
- [ ] T032 [US1] Generate `test/fixtures/disburse/ada/body.cbor`
      once via the same `runDisburseBuildFromFixtures` helper used
      by T030 (a one-shot Hspec entry point added under
      `test/golden/Amaru/Treasury/Tx/Fixture.hs` that writes the
      stripped-ExUnits body to the fixture path). The CLI binary is
      **not** required at this point — Phase 6 (`disburse`
      subcommand) lands later. Commit `body.cbor`. Document the
      exact command (a single `cabal run golden-tests --
      --recorder ada`) in a comment at the top of T030's spec file
      so the next regeneration is mechanical. This step is local
      only (workstation with the local mainnet UTxO snapshot used to
      author `utxos.json`); CI replays the recorded body.cbor and
      never re-records.
- [ ] T033 [US1] Confirm GREEN: rerun T031's command; the golden
      passes byte-for-byte.
- [ ] T034 [P] [US1] Negative test in
      `test/unit/Amaru/Treasury/Tx/DisburseWizardSpec.hs`: stub
      `Provider IO` returns a beneficiary address whose `Network`
      does not match `ResolverInput.network`; assert the resolver
      returns `Left ResolverBeneficiaryNetworkMismatch` (constructor
      from the `ResolverError` block in
      [data-model.md §3](./data-model.md), distinct from the
      pure-translation `DisburseError`). Covers the
      beneficiary-mismatch edge case from `spec.md`.
- [ ] T035 [P] [US1] Negative test: insufficient treasury ADA →
      `Left (ResolverShortfall …)` (the typed shortfall constructor
      from `ResolverError`).
- [ ] T036 [US1] Run `just ci`; the new specs must remain green
      end-to-end.

**Checkpoint**: ADA disburse path is fully wired from
`(DisburseAnswers, Provider IO) → DisburseIntentJSON →
DisburseBuildInputs → unsigned hex CBOR`, with a body-CBOR golden
recorded against the local mainnet node. SC-005 satisfied for ADA.

---

## Phase 5: User Story 2 — USDM disburse + golden (Priority: P1)

> **Story label**: `[US2]` matches `spec.md` US2 ("Produce a valid
> USDM disburse intent.json").

**Goal**: USDM-specific selection + builder, with its own body-CBOR
golden.

**Independent test**: `--match "usdm-disburse"` rebuilds the tx from
`test/fixtures/disburse/usdm/`. Pass = green.

- [ ] T037 [US2] Implement deterministic largest-first treasury UTxO
      selection by **USDM quantity**
      ([research R4](./research.md#r4-treasury-utxo-selection--ada-vs-usdm))
      in `lib/Amaru/Treasury/Tx/DisburseWizard.hs`. Reuse the
      `selectByKey` helper from T026; new `selectByUsdm` is a
      one-liner over the same skeleton. Property test in
      `DisburseWizardSpec.hs`: `Σ usdm on inputs ≥ amount`,
      `tsLeftoverUsdm = Σ usdm − amount`, leftover lovelace and other
      assets preserved.
- [ ] T037a [US2] Add `disburseUsdmRedeemer :: Integer ->
      RawPlutusData` to
      [`Amaru.Treasury.Redeemer`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Redeemer.hs)
      mirroring the existing `disburseAdaRedeemer`. The Plutus-data
      shape encodes the USDM `Value` (a single asset entry under the
      USDM policy + token) per the Sundae treasury redeemer
      [`DisburseValue`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak)
      constructor. Add a `RedeemerSpec` golden hex assertion under
      `test/unit/Amaru/Treasury/RedeemerSpec.hs` recorded once via
      [`make_redeemer_disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_disburse.sh)
      against a USDM amount.
- [ ] T038 [US2] Implement `disburseUsdmProgram :: DisburseIntentFields
      -> Integer -> TxBuild q e ()` in
      `lib/Amaru/Treasury/Tx/Disburse.hs`, consuming the redeemer
      added in T037a. Body shape: same eight operations as
      `disburseAdaProgram`, but the beneficiary output carries
      `MaryValue (getMinCoinTxOut pparams) (singletonAsset
      usdmPolicy usdmAsset amount)` and the leftover output carries
      every other asset present on inputs (including spent ADA).
- [ ] T039 [US2] Extend `runDisburseBuild` in
      `lib/Amaru/Treasury/Tx/DisburseBuild.hs` to dispatch to
      `disburseUsdmProgram` when `dbiIntent` is
      `DisburseUsdmIntent`.
- [ ] T040 [P] [US2] Author USDM body-CBOR fixture set under
      `test/fixtures/disburse/usdm/`: `intent.json`, `utxos.json`
      (synthesized USDM-bearing treasury UTxO), `pparams.json`
      (symlink).
- [ ] T041 [US2] Author
      `test/golden/Amaru/Treasury/Tx/UsdmDisburseGoldenSpec.hs` with
      one `it` block: `"usdm-disburse golden body matches"`. Loads
      T040 fixtures via the shared `runDisburseBuildFromFixtures`
      helper from T030 (no CLI, no node socket), strips ExUnits,
      compares to `test/fixtures/disburse/usdm/body.cbor`.
- [ ] T042 [US2] Confirm RED: run `nix develop -c just golden
      --test-options=--match=usdm-disburse`.
- [ ] T043 [US2] Generate `test/fixtures/disburse/usdm/body.cbor`
      via the same fixture-recorder helper as T032 (no CLI
      dependency). Local-only step; CI replays. Document the exact
      command.
- [ ] T044 [US2] Confirm GREEN: rerun T042's command; the golden
      passes byte-for-byte. Run `just ci` end-to-end.

**Checkpoint**: USDM disburse path is fully wired with its own
golden. Both P1 user stories are deliverable.

---

## Phase 6: User Story 4 — pipe `disburse-wizard | disburse` (Priority: P2)

> **Story label**: `[US4]` matches `spec.md` US4 ("Pipe
> disburse-wizard | disburse end-to-end").

**Goal**: Both subcommands wired in `app/amaru-treasury-tx/Main.hs`,
with the FR-009 / FR-010 / FR-015 pipe contract enforced.

**Independent test**: integration test that exercises `disburse-wizard
... | disburse` against the local mainnet node and verifies stdout is
exactly one line of hex characters.

- [ ] T045 [US4] Add the `disburse-wizard` subcommand parser
      (`DisburseWizardOpts`) and `runDisburseWizard` function to
      `app/amaru-treasury-tx/Main.hs`. Flag set per
      [contracts/disburse-wizard-cli.md §1](./contracts/disburse-wizard-cli.md);
      structure mirrors `runWizard` for swap. Default `--out` to
      stdout when omitted; default `--log` to stderr.
- [ ] T046 [US4] Add the `disburse` subcommand parser (`DisburseOpts`)
      and `runDisburse` function to `app/amaru-treasury-tx/Main.hs`.
      Flag set per
      [contracts/disburse-cli.md §1](./contracts/disburse-cli.md);
      structure mirrors `runSwap`. Default `--intent` to stdin when
      omitted; default `--out` to stdout; default `--summary-out` to
      `disburse.summary.json` in CWD; default `--log` to stderr.
- [ ] T047 [US4] Wire the typed tracers from T010 + T011 into both
      runners; on success, the only stdout content is the intent JSON
      (wizard) or the hex CBOR (build). Stderr (or `--log`) carries
      events one per line.
- [ ] T048 [US4] Wire the exit codes per
      [contracts/disburse-wizard-cli.md §3](./contracts/disburse-wizard-cli.md)
      and [contracts/disburse-cli.md §3](./contracts/disburse-cli.md).
      `DisburseError`, `ResolverError`, parse-failure, and
      build/balance failures each map to a distinct code.
- [ ] T049 [US4] Update the help text + module Haddock at the top of
      `app/amaru-treasury-tx/Main.hs` to mention both new
      subcommands and their pipe shape, mirroring the swap entry.
- [ ] T050 [P] [US4] Smoke script
      `scripts/smoke/disburse-wizard-pipe`: exercises the pipe with
      a fixture metadata.json against a stub-stdin `disburse` build
      (no node required) — asserts the wizard's stdout decodes as
      `DisburseIntentJSON` and that `disburse < intent.json` exits
      `0` with hex on stdout. Records wall-clock duration via
      `time -f '%e'` and fails the script if it exceeds 10 seconds
      (covers SC-002). Mirror
      [`scripts/smoke/swap-wizard-signers`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/scripts/smoke/swap-wizard-signers).
- [ ] T051 [US4] Add the smoke script to the `just smoke` recipe and
      to the CI workflow under
      [`.github/workflows/ci.yml`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/.github/workflows/ci.yml)
      so it runs on every push.
- [ ] T052 [US4] Negative test in
      `test/unit/Amaru/Treasury/Tx/DisburseWizardSpec.hs`: feed
      malformed JSON to `disburse` via stdin (use a
      `withSystemTempFile` helper and call `decodeDisburseIntent`);
      assert exit 3 + single-line stderr.
- [ ] T053 [US4] Run `just ci`; everything green.

**Checkpoint**: pipe shape works end-to-end; SC-002 measurable;
SC-005 covers re-eval failure path.

---

## Phase 7: User Story 5 — summary sidecar (Priority: P3)

> **Story label**: `[US5]` matches `spec.md` US5 ("Summary sidecar
> for inspection before signing").

**Goal**: `disburse` writes a JSON summary at `--summary-out` (default
`disburse.summary.json`) that conforms to
[`summary-schema.json`](../001-treasury-tx-cli/contracts/summary-schema.json).

**Independent test**: parse the summary JSON written by each of the
two goldens and validate against the schema.

- [ ] T054 [US5] Wire `DisburseBuildResult → DisburseSummary` in
      `app/amaru-treasury-tx/Main.hs` and reuse the existing
      [`Amaru.Treasury.Summary`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Summary.hs)
      `ToJSON` instance. Map each `ScriptResult` to a
      `RedeemerSummary` with the per-redeemer `index`, `purpose`,
      `exUnits`, and (when `Left`) `failure`.
- [ ] T055 [P] [US5] Add a golden summary test
      `test/golden/Amaru/Treasury/SummaryGoldenSpec.hs` that runs
      both `disburse` fixtures and validates each emitted summary
      against
      [`specs/001-treasury-tx-cli/contracts/summary-schema.json`](../001-treasury-tx-cli/contracts/summary-schema.json)
      using a hand-rolled validator (Aeson `Value` against the schema's
      `properties` / `required` keys; no new schema-validator
      dependency).
- [ ] T056 [P] [US5] Add a negative case: trigger a per-redeemer
      script failure (use a fixture intent whose treasury input has
      been deliberately mis-paired with a permissions ref); assert
      summary captures the failure and exit code is 1.

**Checkpoint**: summary sidecar contract is enforced.

---

## Phase 8: Polish & cross-cutting concerns

- [ ] T057 [P] Update `README.md` with the disburse-wizard pipe
      example from [quickstart.md](./quickstart.md) §2 and §3.
- [ ] T058 [P] Update `docs/quickstart.md` (the user-facing docs site)
      with the disburse pipe alongside the existing swap pipe.
- [ ] T059 [P] Run `nix develop -c just cabal-check`; resolve any new
      warnings to keep the package Hackage-ready (Constitution VI).
- [ ] T060 [P] Run `nix develop -c just hlint` and
      `nix develop -c just format-check`; resolve any new diagnostics.
- [ ] T061 Update PR description with the final command-line
      reference and link to [quickstart.md](./quickstart.md). Use
      `gh pr edit` after every push to keep the description in sync
      with the diff.
- [ ] T062 Manual preprod E2E per
      [quickstart.md §9](./quickstart.md): produce `intent.json` with
      the wizard against `--network preprod`, hand-sign offline,
      submit, observe. Record the run in the PR description.
- [ ] T063 On 004 merge, unblock the follow-up features:
      [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
      (withdraw-wizard) and
      [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
      (reorganize-wizard) were filed at the start of the path with
      `blockedBy = #44`. This task removes the `blockedBy` edges via
      `gh api graphql … removeBlockedBy …` and posts a comment on
      both issues announcing that work can start.

**Checkpoint**: ready for review and merge once #44's PR is green.

---

## Dependencies

```
Setup (T001-T004)
    └── Foundational (T005-T013)
            └── Phase 3 [US3] pure translation (T014-T024) ── MVP gate
                    └── Phase 4 [US1] ADA resolver + golden (T025-T036)
                            └── Phase 5 [US2] USDM golden (T037-T037a-T038-T044)
                                    └── Phase 6 [US4] pipe (T045-T053)
                                            └── Phase 7 [US5] summary (T054-T056)
                                                    └── Phase 8 polish (T057-T063)
```

Phase 3 (`[US3]` pure translation) is the MVP gate. Phase 4 + 5
(`[US1]` + `[US2]`) consume `disburseToIntentJSON`. Phase 6 (`[US4]`
CLI pipe) wires both into the subcommands; Phase 7 (`[US5]`) adds the
summary sidecar; Phase 8 polishes for review.

## Parallel opportunities

- **Within Phase 1**: T002, T003, T004 are independent; the cabal edit
  T001 must land first.
- **Within Phase 2**: T006, T007, T009, T011, T012 are file-disjoint
  and can land in any order after T005 + T010.
- **Within Phase 3**: T014, T015, T016, T017, T018, T019 are
  fixture-only and can be authored in parallel before T020.
- **Within Phase 4**: T027, T034, T035 are property/negative tests
  independent of the IO glue in T025/T028.
- **Within Phase 5**: T040 is fixture-only.
- **Within Phase 6**: T050 (smoke script) is independent of T045/T046.
- **Within Phase 7**: T055, T056 are independent.
- **Within Phase 8**: T057, T058, T059, T060 are all `[P]`.

## MVP scope

**MVP = Phase 1 + Phase 2 + Phase 3.** Proves the typed translation
matches the JSON contract for both `--unit ada` and `--unit usdm` and
earns the goldens. Phase 4 + 5 land the body-CBOR goldens; Phase 6
makes the wizard usable from the CLI; Phase 7 adds the operator audit
sidecar; Phase 8 closes out review.

## Out of scope for this feature

- Withdraw and reorganize subcommands — tracked as
  [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
  and
  [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46).
- A live preprod-end-to-end smoke that signs and submits — its own
  follow-up issue, opened in T063.
- Refactoring the shared `NetworkConstants` table out of
  `Tx.SwapWizard` into a separate module — deferred until a third
  caller appears (research [§R7](./research.md#r7-networkconstants-reuse)).
