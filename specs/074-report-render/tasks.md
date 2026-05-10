# Tasks: Operator-Friendly Markdown Renderer (`report-render`)

**Input**: Design documents from `specs/074-report-render/`
**Prerequisites**: `spec.md`, `plan.md`, `research.md`,
`data-model.md`, `contracts/report-render-cli.md`, `quickstart.md`

This task list follows the solo PR flow. RED and GREEN tasks are shown
separately so the work is explicit, but every RED/GREEN group named in
the notes must be folded into one bisect-safe vertical commit before
handoff or review.

## Phase 1: Setup

**Purpose**: Add the empty structure needed for incremental slices
without changing runtime behavior.

- [x] T001 Create placeholder modules with explicit export lists for `lib/Amaru/Treasury/Report/Render.hs`, `lib/Amaru/Treasury/Report/Render/Address.hs`, `lib/Amaru/Treasury/Report/Render/Markdown.hs`, `lib/Amaru/Treasury/Report/Render/Time.hs`, `lib/Amaru/Treasury/Report/Identity.hs`, `lib/Amaru/Treasury/Report/Identity/Resolve.hs`, `lib/Amaru/Treasury/Report/Identity/Constants.hs`, and `lib/Amaru/Treasury/Report/Cli.hs`
- [x] T002 Wire the new library modules and planned test modules into `amaru-treasury-tx.cabal`
- [x] T003 [P] Create fixture directories for `test/fixtures/disburse/`, `test/fixtures/withdraw/`, and additional report-render files under `test/fixtures/swap/`

## Phase 2: Foundational Envelope Contract

**Purpose**: Establish the self-contained build-output envelope that
all user stories consume. Fold T004-T009 into one vertical contract
commit.

- [x] T004 Add RED unit tests for `TxBuildOutput`, `TxBuildOutputResult`, `TxBuildSuccess`, and `TxCborHex` encoding/decoding in `test/unit/Amaru/Treasury/ReportSpec.hs`
- [x] T005 Add RED schema tests for required `intent`, required `result`, success `tx-cbor`, nested success `report`, failure `failure`, and no duplicate action/type in `test/unit/Amaru/Treasury/ReportSchemaSpec.hs`
- [x] T006 Implement `TxBuildOutput`, `TxBuildOutputResult`, `TxBuildSuccess`, and `TxCborHex` plus JSON instances in `lib/Amaru/Treasury/Report.hs`
- [x] T007 Remove any duplicate transaction-type/action carrier from the nested mechanical report JSON contract in `lib/Amaru/Treasury/Report.hs`
- [x] T008 Update schema generation for the build-output envelope in `lib/Amaru/Treasury/Report/Schema.hs` and `docs/assets/tx-report-schema.json`
- [x] T009 Run the envelope contract gate with `nix build --quiet --no-link ".#checks.${SYS}.unit" ".#checks.${SYS}.schema" ".#checks.${SYS}.lint"`

## Phase 3: User Story 1 - Render Mechanical Report Markdown (P1)

**Goal**: Render a successful build-output envelope into deterministic
operator-friendly Markdown with collapsed outputs, ADA/lovelace
display, UTC validity, conservation, explorer URL, CIP-1694 rationale,
and CBOR fingerprint/hash.

**Independent Test**: Render `test/fixtures/swap/report.golden.json`
twice and verify byte-identical output that includes the required
leading-section facts and matches `test/fixtures/swap/report.golden.md`.
Fold T010-T020 into one vertical renderer commit.

- [x] T010 [P] [US1] Add RED pure-render tests for lovelace/ADA formatting, output collapsing, conservation arithmetic, explorer URL, and CBOR fingerprint/hash in `test/unit/Amaru/Treasury/Report/RenderSpec.hs`
- [x] T011 [P] [US1] Add RED slot-to-UTC derivation tests using report era/network data in `test/unit/Amaru/Treasury/Report/RenderSpec.hs`
- [x] T012 [P] [US1] Add RED swap Markdown golden test in `test/golden/ReportRenderSwapGoldenSpec.hs`
- [x] T013 [US1] Add success envelope fixture with inline intent, `result.tx-cbor`, and nested `result.report` in `test/fixtures/swap/report.golden.json`
- [x] T014 [US1] Implement deterministic Markdown builder primitives in `lib/Amaru/Treasury/Report/Render/Markdown.hs`
- [x] T015 [US1] Implement slot-to-UTC derivation from report era/network data in `lib/Amaru/Treasury/Report/Render/Time.hs`
- [x] T016 [US1] Implement success report rendering and section ordering in `lib/Amaru/Treasury/Report/Render.hs`
- [x] T017 [US1] Implement produced-output grouping and amount display in `lib/Amaru/Treasury/Report/Render.hs`
- [x] T018 [US1] Render transaction id, explorer URL, CBOR fingerprint/hash, validity bounds, conservation line, and CIP-1694 rationale in `lib/Amaru/Treasury/Report/Render.hs`
- [x] T019 [US1] Add full swap Markdown golden output in `test/fixtures/swap/report.golden.md`
- [x] T020 [US1] Run the US1 gate with `nix build --quiet --no-link ".#checks.${SYS}.unit" ".#checks.${SYS}.golden" ".#checks.${SYS}.lint"`

## Phase 4: User Story 2 - Identity Resolution and Transaction Type Recognition (P1)

**Goal**: Label every printed address, signer key hash, and reference
input, and identify transaction type from inline intent in the leading
section.

**Independent Test**: Render swap, disburse, and withdraw fixtures and
verify the leading section identifies transaction type and scope while
the Markdown contains no bare bech32 address or bare 28-byte hex key
hash outside `unresolved (...)`. Fold T021-T032 into one vertical
identity commit.

- [x] T021 [P] [US2] Add RED address-book resolution priority tests in `test/unit/Amaru/Treasury/Report/IdentitySpec.hs`
- [x] T022 [P] [US2] Add RED signer identity-map tests for role labels, no personal names, and unresolved fallback in `test/unit/Amaru/Treasury/Report/IdentitySpec.hs`
- [x] T023 [P] [US2] Add RED bare bech32 and bare 28-byte hex post-condition assertions in `test/golden/ReportRenderSwapGoldenSpec.hs`
- [x] T024 [US2] Implement address-book and identity-map types in `lib/Amaru/Treasury/Report/Identity.hs`
- [x] T025 [US2] Implement built-in constants for USDM, Sundae pool, and Sundae fee identifiers in `lib/Amaru/Treasury/Report/Identity/Constants.hs`
- [x] T026 [US2] Implement metadata, built-in, script-derivation, intent, and unresolved resolution order in `lib/Amaru/Treasury/Report/Identity/Resolve.hs`
- [x] T027 [US2] Implement safe address and key-hash formatting helpers in `lib/Amaru/Treasury/Report/Render/Address.hs`
- [x] T028 [US2] Source transaction type and scope from inline intent in `lib/Amaru/Treasury/Report/Render.hs`
- [x] T029 [US2] Apply resolved labels to inputs, outputs, reference inputs, and signer sections in `lib/Amaru/Treasury/Report/Render.hs`
- [x] T030 [US2] Add disburse success envelope and Markdown golden fixtures in `test/fixtures/disburse/report.golden.json` and `test/fixtures/disburse/report.golden.md`
- [x] T031 [US2] Add withdraw success envelope and Markdown golden fixtures in `test/fixtures/withdraw/report.golden.json` and `test/fixtures/withdraw/report.golden.md`
- [x] T032 [US2] Run the US2 gate with `nix build --quiet --no-link ".#checks.${SYS}.unit" ".#checks.${SYS}.golden" ".#checks.${SYS}.lint"`

## Phase 5: User Story 3 - Pipeline and CLI Composition (P1)

**Goal**: Make `tx-build --report - | report-render > report.md`
work without a separate intent argument, with clear invalid-envelope
and failure-result diagnostics.

**Independent Test**: Pipe a fixture build-output stream through
`report-render` with no flags, then repeat with `--in`, `--out`, and
stdio aliases. Invalid envelopes fail non-zero with clear diagnostics.
Fold T033-T045 into one vertical pipeline commit.

- [x] T033 [P] [US3] Add RED CLI parser tests for `report-render`, `--in`, `--out`, `--metadata`, and stdio aliases in `test/unit/Amaru/Treasury/Report/CliSpec.hs`
- [x] T034 [P] [US3] Add RED parser rejection tests proving `report-render` has no `--intent` or `--no-intent` argument in `test/unit/Amaru/Treasury/Report/CliSpec.hs`
- [x] T035 [P] [US3] Add RED invalid-envelope tests for missing or malformed `intent`, `result`, success `tx-cbor`, and success `report` in `test/unit/Amaru/Treasury/Report/CliSpec.hs`
- [x] T036 [P] [US3] Add invalid envelope fixtures in `test/fixtures/swap/report.missing-required-fields.json` and `test/fixtures/swap/report.malformed-required-fields.json`
- [x] T037 [US3] Implement `ReportRenderOpts` and parser helpers in `lib/Amaru/Treasury/Report/Cli.hs`
- [x] T038 [US3] Wire the `report-render` subcommand into `app/amaru-treasury-tx/Main.hs`
- [x] T039 [US3] Implement JSON envelope decode, default stdin/stdout IO, explicit `--in` and `--out`, and output-write failure handling in `app/amaru-treasury-tx/Main.hs`
- [x] T040 [US3] Implement failure-envelope diagnostic rendering with non-zero exit in `app/amaru-treasury-tx/Main.hs`
- [x] T041 [US3] Extend `tx-build --report` to accept `-` as stdout in `lib/Amaru/Treasury/Cli/TxBuild.hs`
- [x] T042 [US3] Wrap successful `tx-build --report` output as `{ intent, result: { tx-cbor, report } }` in `app/amaru-treasury-tx/Main.hs`
- [x] T043 [US3] Wrap post-intent-decode build failures as `{ intent, result: { failure } }` in `lib/Amaru/Treasury/Cli/TxBuild.hs`
- [x] T044 [US3] Add smoke coverage for `report-render --help` and `tx-build --report - | report-render` in `nix/checks.nix`
- [x] T045 [US3] Run the US3 gate with `nix build --quiet --no-link ".#checks.${SYS}.unit" ".#checks.${SYS}.golden" ".#checks.${SYS}.smoke" ".#checks.${SYS}.lint"`

## Phase 6: User Story 4 - Documentation and Operator Helper (P2)

**Goal**: Make Markdown rendering the documented default pre-signing
review artifact and provide the `scripts/ops/build-swop` helper with a
documented `--no-markdown` opt-out.

**Independent Test**: Run the helper against the swap fixture and
verify default JSON plus Markdown output, then verify `--no-markdown`
keeps JSON and suppresses Markdown. Fold T046-T052 into one vertical
docs/helper commit.

- [x] T046 [P] [US4] Add RED smoke assertions for helper default-on Markdown behavior in `nix/checks.nix`
- [x] T047 [P] [US4] Add RED smoke assertions for helper `--no-markdown` behavior in `nix/checks.nix`
- [x] T048 [US4] Implement POSIX-shell helper in `scripts/ops/build-swop`
- [x] T049 [US4] Document renderer contract, envelope shape, identity sources, determinism, failure handling, and helper opt-out in `docs/report-render.md`
- [x] T050 [US4] Update the pre-signing review flow in `docs/quickstart.md`
- [x] T051 [US4] Update the swap operator flow in `docs/swap.md`
- [x] T052 [US4] Run the US4 gate with `nix build --quiet --no-link ".#checks.${SYS}.smoke" ".#checks.${SYS}.lint"`

## Phase 7: Polish and Cross-Cutting Gates

**Purpose**: Verify the whole PR after the vertical slices have landed.

- [ ] T053 Add Haddock notes for public renderer and envelope APIs in `lib/Amaru/Treasury/Report.hs` and `lib/Amaru/Treasury/Report/Render.hs`
- [ ] T054 Regenerate any checked-in golden JSON or Markdown fixture updates through the repository's existing golden workflow documented in `test/`
- [ ] T055 Run `git diff --check`
- [ ] T056 Run the full local gate with `nix build --quiet --no-link ".#checks.${SYS}.build" ".#checks.${SYS}.unit" ".#checks.${SYS}.golden" ".#checks.${SYS}.schema" ".#checks.${SYS}.lint" ".#checks.${SYS}.smoke"`
- [ ] T057 Review the PR title and body against `specs/074-report-render/spec.md`, `specs/074-report-render/contracts/report-render-cli.md`, and issue #74
- [ ] T058 Handoff for external review without self-approving the PR in GitHub

## Dependencies

Phase 2 blocks all user stories because the renderer consumes the
build-output envelope.

US1 is the MVP and can ship a useful success renderer once Phase 2 is
complete. US2 builds on US1's sections to add labels and transaction
recognition. US3 builds on Phase 2 and US1 to wire streams and CLI
composition. US4 depends on US3 for the helper's end-to-end behavior.

## Parallel Opportunities

Within Phase 3, T010, T011, and T012 can be authored in parallel
because they touch separate test concerns. Within Phase 4, T021, T022,
and T023 can be authored in parallel. Within Phase 5, T033, T034, T035,
and T036 can be authored in parallel. Within Phase 6, T046 and T047 can
be authored in parallel.

## Implementation Strategy

1. Complete Phase 2 first so every downstream artifact has the same
   envelope contract.
2. Deliver US1 as the MVP: one success fixture, pure renderer,
   deterministic Markdown golden.
3. Add US2 identity resolution and transaction-type recognition before
   widening CLI exposure, so the public command never emits unsafe bare
   identifiers.
4. Add US3 pipeline behavior and invalid/failure diagnostics.
5. Finish with US4 docs/helper and the full local gate.
