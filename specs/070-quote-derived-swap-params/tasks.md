# Tasks: Quote-Derived Swap Parameters

**Input**: Approved design documents from
[`specs/070-quote-derived-swap-params/`](.)

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/swap-quote-cli.md](./contracts/swap-quote-cli.md),
[contracts/swap-quote-audit-json.md](./contracts/swap-quote-audit-json.md),
[quickstart.md](./quickstart.md)

**Tracking issue**: [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70)

**Tracking PR**: [#71](https://github.com/lambdasistemi/amaru-treasury-tx/pull/71)

**Scope reminder**: this feature adds the quote-derived `swap-quote`
operator path. It MUST support ADA/USD quote overrides, explicit
ADA/USDM quote overrides, and the named live `coingecko-ada-usd`
source. A named live ADA/USDM source is deferred until a future issue
selects and approves a provider contract.

**Tests**: Required by the approved spec and Constitution V. Each
behavior slice starts with RED proof, then lands the implementation and
evidence in the same durable work commit so the branch stays
reviewable one vertical commit at a time.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable with other tasks in the same phase
- **[Story]**: user story label from [spec.md](./spec.md)
- File paths are relative to repository root

## Path Conventions

- Pure quote module: `lib/Amaru/Treasury/Tx/SwapQuote.hs`
- Quote-source module: `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs`
- Existing swap wizard reuse points:
  `lib/Amaru/Treasury/Tx/SwapWizard.hs` and
  `lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs`
- CLI entry point: `app/amaru-treasury-tx/Main.hs`
- Cabal package file: `amaru-treasury-tx.cabal`
- Unit tests: `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs`
- Golden tests: `test/golden/SwapQuoteAuditGoldenSpec.hs`
- Deterministic fixtures: `test/fixtures/swap-quote/`
- Smoke scripts: `scripts/smoke/`
- Documentation: `docs/quickstart.md` and `docs/swap.md`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the compile/test surface without changing runtime
behavior.

- [x] T001 Add `Amaru.Treasury.Tx.SwapQuote` and `Amaru.Treasury.Tx.SwapQuote.Source` to the library exposed modules in `amaru-treasury-tx.cabal`.
- [x] T002 Add skeleton module files `lib/Amaru/Treasury/Tx/SwapQuote.hs` and `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs` with explicit export lists.
- [x] T003 [P] Add `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` to the `unit-tests` stanza in `amaru-treasury-tx.cabal`.
- [x] T004 [P] Add `test/golden/SwapQuoteAuditGoldenSpec.hs` to the `golden-tests` stanza in `amaru-treasury-tx.cabal`.
- [x] T005 Add fixture globs for `test/fixtures/swap-quote/**/*.json` and `test/fixtures/swap-quote/**/*.md` to `extra-source-files` in `amaru-treasury-tx.cabal`.
- [x] T006 Add the required dependencies for the planned implementation to `amaru-treasury-tx.cabal`: `scientific` and `http-conduit` for the library, plus any executable-only dependencies required by the `swap-quote` runner.
- [x] T007 Run `nix develop --quiet -c just build` and `nix develop --quiet -c just format-check` to confirm the empty scaffolding compiles and is formatted.

**Checkpoint**: The package compiles with empty `SwapQuote` and
`SwapQuote.Source` scaffolding, and no cabal fixture glob is empty.

---

## Phase 2: User Story 1 - Quote and Slippage Derivation (Priority: P1) MVP

**Goal**: Deterministic ADA/USD and ADA/USDM quote overrides plus
explicit slippage derive the minimum rate without manual arithmetic.

**Independent Test**: `nix develop --quiet -c just unit SwapQuote`
proves derivation, validation, exact decimal parsing, and conservative
rounding for deterministic inputs without live network access.

### Tests for User Story 1

- [x] T008 [P] [US1] Add RED derivation tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` for `quote * (10000 - slippageBps) / 10000`, including the plan fixture `0.8123` and `100` bps producing rate numerator `804177` over denominator `1000000`.
- [x] T009 [P] [US1] Add RED validation tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` for missing slippage, negative slippage text, slippage `>= 10000`, unparsable quote text, zero quote, and negative quote.
- [x] T010 [P] [US1] Add RED ADA/USDM override tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving `--ada-usdm` creates an ADA/USDM override observation and never requires a named live ADA/USDM source.
- [x] T011 [P] [US1] Add RED rounding tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving rate numerator floors and requested ADA/chunk lovelace values ceiling from exact rational inputs.

### Implementation for User Story 1

- [x] T012 [US1] Implement `QuotePair`, `QuoteProvenance`, `QuoteObservation`, `SlippageBps`, `QuoteInput`, and exact decimal parsing in `lib/Amaru/Treasury/Tx/SwapQuote.hs`.
- [x] T013 [US1] Implement `deriveSwapParameters` in `lib/Amaru/Treasury/Tx/SwapQuote.hs` with exact rational math, six-decimal rate denominator, floor rate rounding, and ceiling ADA conversions.
- [x] T014 [US1] Implement parser-facing helpers for `--ada-usd`, `--ada-usdm`, and `--slippage-bps` in `lib/Amaru/Treasury/Tx/SwapQuote.hs`, returning typed errors before any quote fetch or intent generation.
- [x] T015 [US1] Run `nix develop --quiet -c just unit SwapQuote` and record the RED failure command/result before T012-T014 plus the GREEN pass command/result after T012-T014 in the work-review handoff.

**Checkpoint**: US1 acceptance scenarios 1 and 2 pass for explicit
quote overrides; SC-001 is covered without live network access.

---

## Phase 3: User Story 2 - Affordability Check (Priority: P1)

**Goal**: The quote-derived path stops unaffordable swaps before
unsigned CBOR output and reports the economic shortfall.

**Independent Test**: `nix develop --quiet -c just unit SwapQuote`
proves exact equality is affordable, one lovelace short is not, and
the required total uses generated chunk count and
`extraPerChunkLovelace`.

### Tests for User Story 2

- [x] T016 [P] [US2] Add RED affordability exact-pass and one-lovelace-short tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs`.
- [x] T017 [P] [US2] Add RED generated-chunk-count tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving required lovelace is `amountLovelace + chunk_count * extraPerChunkLovelace`.
- [x] T018 [P] [US2] Add RED diagnostic rendering tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` covering required ADA, available ADA, quote, slippage, and shortfall in the unaffordable error.

### Implementation for User Story 2

- [x] T019 [US2] Implement `AffordabilitySummary` and `checkAffordability` in `lib/Amaru/Treasury/Tx/SwapQuote.hs`.
- [x] T020 [US2] Implement typed affordability failure rendering in `lib/Amaru/Treasury/Tx/SwapQuote.hs`.
- [x] T021 [US2] Refactor or expose the minimal generated intent/chunk-count helper needed from `lib/Amaru/Treasury/Tx/SwapWizard.hs` so `swap-quote` uses generated intent values rather than operator estimates.
- [x] T022 [US2] Run `nix develop --quiet -c just unit SwapQuote` and record the RED failure command/result before T019-T021 plus the GREEN pass command/result after T019-T021 in the work-review handoff.

**Checkpoint**: US2 acceptance scenarios 1-3 pass at the pure summary
level before CLI wiring.

---

## Phase 4: User Story 3 - Audit JSON Contract (Priority: P2)

**Goal**: Successful and affordability-failed runs produce an auditable
`params.json` artifact with quote provenance, slippage, derived rate,
request inputs, affordability values, selected treasury total, status,
and output paths.

**Independent Test**: `nix develop --quiet -c just golden SwapQuote`
or the focused golden selector compares deterministic audit JSON
fixtures byte-for-byte without live network access.

### Tests for User Story 3

- [x] T023 [P] [US3] Add deterministic quote fixture files `test/fixtures/swap-quote/quote.ada-usd.override.json` and `test/fixtures/swap-quote/quote.ada-usdm.override.json`.
- [x] T024 [P] [US3] Add `test/fixtures/swap-quote/params.built.expected.json` covering the required fields from `contracts/swap-quote-audit-json.md`.
- [x] T025 [P] [US3] Add `test/fixtures/swap-quote/params.affordability-failed.expected.json` proving failed affordability writes diagnostic audit data with no unsigned CBOR path.
- [x] T026 [US3] Add RED audit golden tests in `test/golden/SwapQuoteAuditGoldenSpec.hs` for built and affordability-failed artifacts.

### Implementation for User Story 3

- [x] T027 [US3] Implement `SwapQuoteAudit`, `SwapQuoteOutputs`, and `SwapQuoteStatus` in `lib/Amaru/Treasury/Tx/SwapQuote.hs`.
- [x] T028 [US3] Implement stable JSON encoding for `SwapQuoteAudit` in `lib/Amaru/Treasury/Tx/SwapQuote.hs`, preserving exact rational decision values as strings and lovelace/rate integers as JSON integers.
- [x] T029 [US3] Implement audit artifact writing helpers in `lib/Amaru/Treasury/Tx/SwapQuote.hs` that fail visibly when `params.json` cannot be written.
- [x] T030 [US3] Run `nix develop --quiet -c just golden SwapQuote` or `nix develop --quiet -c just golden SwapQuoteAudit` and record the RED failure command/result before T027-T029 plus the GREEN pass command/result after T027-T029 in the work-review handoff.

**Checkpoint**: US3 acceptance scenario 1 is covered for successful
fixture runs, and scenario 2 is covered for affordability failures.

---

## Phase 5: User Story 1 - Named ADA/USD Source and CLI Parser (Priority: P1)

**Goal**: The operator-facing `swap-quote` parser accepts exactly one
quote input and can resolve `coingecko-ada-usd` behind an injectable
provider, while named live ADA/USDM sources remain rejected as out of
scope.

**Independent Test**: Unit tests validate parser/source behavior with
a captured CoinGecko JSON fixture and no live HTTP dependency in CI.

### Tests for User Story 1

- [x] T031 [P] [US1] Add `test/fixtures/swap-quote/source.coingecko.json` with a captured `cardano.usd` response.
- [x] T032 [P] [US1] Add RED provider parsing tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` for `coingecko-ada-usd`, source provenance, fetch time, ADA/USD pair, and raw metadata retention.
- [x] T033 [P] [US1] Add RED parser tests in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` or a focused CLI parser spec proving exactly one of `--ada-usd`, `--ada-usdm`, and `--price-source` is accepted.
- [x] T034 [P] [US1] Add RED parser/source rejection tests proving named live ADA/USDM sources are rejected with a future-work message while explicit `--ada-usdm` overrides are accepted.

### Implementation for User Story 1

- [x] T035 [US1] Implement `QuoteProvider`, `QuoteSourceError`, and captured-response parsing in `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs`.
- [x] T036 [US1] Implement the production `coingecko-ada-usd` provider in `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs` with one HTTP GET, a short timeout, and typed failure before intent JSON or CBOR output.
- [x] T037 [US1] Add `SwapQuoteOpts` and the `swap-quote` subcommand parser to `app/amaru-treasury-tx/Main.hs`, requiring explicit slippage and exactly one quote input.
- [x] T038 [US1] Wire parser validation so named live ADA/USDM source support remains unavailable unless the approved spec changes, while explicit `--ada-usdm` remains supported.
- [x] T039 [US1] Run `nix develop --quiet -c just unit SwapQuote` and a focused `nix develop --quiet -c cabal test unit-tests --test-show-details=direct --test-options='--match swap-quote'` if a parser spec is added outside `SwapQuoteSpec`; record RED/GREEN evidence in the work-review handoff.

**Checkpoint**: US1 acceptance scenario 3 passes for the named
ADA/USD source contract, and the explicit ADA/USDM override contract
remains intact.

---

## Phase 6: User Stories 1, 2, and 3 - Composite Runner and Build Integration (Priority: P1/P2)

**Goal**: `swap-quote` performs quote resolution, existing swap intent
generation, affordability validation, existing unsigned build, and
audit writing in one command.

**Independent Test**: A deterministic CLI smoke path with quote
overrides reaches the normal intent/build outputs when affordable and
stops before `swap.cbor.hex` when unaffordable.

### Tests for User Stories 1, 2, and 3

- [x] T040 [P] [US1] Add RED deterministic runner test coverage in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving derived `SwapWizardQ` values match the existing manual `--min-rate` path for the same derived rate.
- [x] T041 [P] [US2] Add RED runner test coverage in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving affordability failure exits before unsigned CBOR is written while still producing the failure audit summary.
- [x] T042 [P] [US3] Add RED output-path coverage in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` proving successful runs report `intent.json`, `swap.cbor.hex`, `params.json`, `wizard.log`, and `build.log`.
- [x] T043 [P] [US1] Add `scripts/smoke/swap-quote-override` with a deterministic override path using existing swap fixtures and no live quote source.

### Implementation for User Stories 1, 2, and 3

- [x] T044 [US1] Refactor `app/amaru-treasury-tx/Main.hs` just enough to reuse the existing swap wizard resolver and intent builder from the `swap-quote` runner without changing the manual `swap-wizard --min-rate` override path.
- [x] T045 [US1] Implement the `swap-quote` runner in `app/amaru-treasury-tx/Main.hs`, including quote resolution, derived `SwapWizardQ` construction, `intent.json` writing, and `wizard.log` writing.
- [x] T046 [US2] Integrate `checkAffordability` after generated intent/chunk values are known and before `runFromIntent` writes unsigned CBOR in `app/amaru-treasury-tx/Main.hs`.
- [x] T047 [US3] Integrate `params.json` writing for both built and affordability-failed results in `app/amaru-treasury-tx/Main.hs`.
- [x] T048 [US1] Preserve the existing manual `swap-wizard --min-rate` behavior and tests while adding `swap-quote`; no existing manual override output should change except where explicitly covered by new tests.
- [x] T049 [US1] Wire `scripts/smoke/swap-quote-override` into the `smoke` recipe in `justfile`.
- [x] T050 [US1] Run `nix develop --quiet -c just unit SwapQuote`, `nix develop --quiet -c just smoke`, and `nix develop --quiet -c just golden swap`; record RED/GREEN evidence in the work-review handoff.

**Checkpoint**: US1, US2, and US3 are executable through the operator
CLI with deterministic quote overrides and existing build artifacts.

---

## Phase 7: User Story 4 - Documentation Makes Safe Path Primary (Priority: P3)

**Goal**: Documentation presents `swap-quote` as the normal workflow
and labels direct `swap-wizard --min-rate` use as an expert/manual
override with audit responsibility.

**Independent Test**: Documentation checks show the primary swap path
requires a fresh quote source or quote override plus explicit
slippage, and no recommended example keeps the stale
`--min-rate 0.245` path.

### Tests for User Story 4

- [x] T051 [P] [US4] Add a documentation regression check in `scripts/smoke/swap-quote-docs` or an equivalent shell check proving `docs/swap.md` does not present `--min-rate 0.245` as the recommended path.
- [x] T052 [P] [US4] Add `swap-quote --help` coverage to the release or smoke path in `scripts/smoke/swap-quote-override` so the new operator command is protected by CLI smoke tests.

### Implementation for User Story 4

- [x] T053 [US4] Update `docs/quickstart.md` so the primary swap example uses `swap-quote` with `--price-source coingecko-ada-usd` or a deterministic quote override plus `--slippage-bps`.
- [x] T054 [US4] Update `docs/swap.md` so direct `swap-wizard --min-rate` examples are labelled expert/manual override and explain the external audit responsibility.
- [x] T055 [US4] Document explicit `--ada-usdm` override support and the deferred named live ADA/USDM source in `docs/swap.md`.
- [x] T056 [US4] Wire `scripts/smoke/swap-quote-docs` into `just smoke` if a script is used, then run `nix develop --quiet -c just smoke` and strict docs build with `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs build --strict --site-dir site`; record RED/GREEN evidence in the work-review handoff.

**Checkpoint**: SC-004 and SC-005 are covered by documentation and
smoke evidence.

---

## Phase 8: Final Verification and Release Readiness

**Purpose**: Prove the full feature remains Hackage-ready and CI-aligned.

- [x] T057 Run `nix develop --quiet -c just ci` and confirm build, schema check, unit tests, golden tests, format check, hlint, smoke, and release check pass.
- [x] T058 Run `nix develop --quiet -c just cabal-check` and confirm package metadata remains Hackage-ready after new modules, fixtures, and dependencies.
- [x] T059 Review `specs/070-quote-derived-swap-params/quickstart.md`, `docs/quickstart.md`, and `docs/swap.md` together to ensure the ADA/USD source path, explicit ADA/USDM override path, and deferred named live ADA/USDM source statement are consistent.
- [x] T060 Update the PR finalization notes or PR body draft with completed task IDs, gate commands, and any explicitly deferred follow-up for named live ADA/USDM sources.

**Checkpoint**: Full local gate and Hackage-readiness checks are green;
all implemented task IDs are ready for reviewer finalization.

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 must complete before source, parser, or test modules can compile.
- Phase 2 is the MVP core and blocks all later phases.
- Phase 3 depends on Phase 2 derived lovelace and chunk calculations.
- Phase 4 depends on Phase 2 and Phase 3 data types.
- Phase 5 depends on Phase 2 quote types and validation semantics.
- Phase 6 depends on Phases 2-5 and integrates the vertical CLI path.
- Phase 7 depends on the command shape from Phase 6.
- Phase 8 depends on all implemented behavior and documentation.

### User Story Dependencies

- **US1**: Starts after Phase 1; quote overrides and derivation are the
  MVP. The named ADA/USD source is added after pure override behavior
  is green.
- **US2**: Starts after US1 derivation because affordability depends on
  generated ADA/chunk values.
- **US3**: Starts after US1 and US2 types exist because audit JSON binds
  quote, derived parameters, affordability, and output paths.
- **US4**: Starts after the CLI command shape is implemented, but docs
  examples can be drafted in parallel once the parser contract is stable.

### Parallel Opportunities

- T003, T004, and T005 can run in parallel after T001.
- T008, T009, T010, and T011 can be written in parallel as RED tests.
- T016, T017, and T018 can be written in parallel as RED tests.
- T023, T024, and T025 can be prepared in parallel as deterministic fixtures.
- T031, T032, T033, and T034 can be written in parallel because they target
  provider parsing and parser validation.
- T040, T041, T042, and T043 can be prepared in parallel once the pure runner
  contract is available.
- T051 and T052 can be written in parallel with T053-T055 once command help and
  documentation wording are stable.

---

## Reviewable Work Commit Strategy

1. **Scaffold commit**: T001-T007 only. No runtime behavior change.
2. **Pure derivation commit**: T008-T015. RED then GREEN proof for quote,
   slippage, ADA/USD override, explicit ADA/USDM override, and rounding.
3. **Affordability commit**: T016-T022. RED then GREEN proof for exact pass,
   one-lovelace short fail, generated chunk count, and diagnostic content.
4. **Audit JSON commit**: T023-T030. RED then GREEN golden proof for built and
   affordability-failed `params.json`.
5. **Source/parser commit**: T031-T039. RED then GREEN proof for
   `coingecko-ada-usd`, exactly-one quote input, and deferred named live
   ADA/USDM source support.
6. **Composite runner commit**: T040-T050. RED then GREEN proof that
   `swap-quote` reuses the existing swap wizard and build path, writes expected
   outputs, and stops before CBOR on unaffordability.
7. **Docs/smoke commit**: T051-T056. RED then GREEN proof that documentation
   presents `swap-quote` as primary and manual `--min-rate` as expert override.
8. **Final verification commit or handoff note**: T057-T060. No new behavior;
   records full gate evidence and any explicit follow-up.

Each behavior commit must run `./llm/reviews/gate.sh` before handoff and record
the exact command/result in `llm/reviews/work-review.md`.
