# Feature Specification: `reorganize-wizard` parser scaffold

**Feature Branch**: `186-reorganize-wizard-parser`
**Created**: 2026-05-22
**Status**: Draft
**GitHub Issue**: [#186](https://github.com/lambdasistemi/amaru-treasury-tx/issues/186)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189) — reorganize transaction end-to-end
**Feature Anchor**: [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
**Depends on**: [#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185) — real `ReorganizeIntent` shapes (already merged at `da9d65b5`)
**Sibling children (later, depend on this slice merging first)**:

- [#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187) — `reorganize-wizard` runner + DevNet guard (wires the runner body this slice stubs)
- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87) — DevNet smoke (live CLI reorganize)
- [#188](https://github.com/lambdasistemi/amaru-treasury-tx/issues/188) — docs + asciinema cast

**Input**: Ship the operator-facing `reorganize-wizard` subcommand
surface in the `amaru-treasury-tx` executable. The subcommand exposes
the documented flag set via `optparse-applicative`, validates every
flag at parse time (TxIn format, required-flag presence, `--network`
restricted to `devnet`, `--out` parent directory exists), and dispatches
to a typed stub runner that exits non-zero with a `TODO Slice C`
error. The actual runner body — chain query, treasury UTxO selection,
validity-bound sampling, intent encode — is the next child (#187) and
is explicitly out of scope here.

Mirrors the existing sibling wizard parser scaffolds — `registry-init-wizard`,
`stake-reward-init-wizard`, `governance-withdrawal-init-wizard` —
which were each shipped as a "Slice 1" parser-only scaffold before
their live runners were wired in subsequent slices.

> **Scope framing:** this slice is the **CLI parser surface** only.
> No chain query, no UTxO selection, no validity-bound sampling, no
> intent encoding, no DevNet smoke, no docs / asciinema. After this
> slice an operator can type `amaru-treasury-tx reorganize-wizard --help`
> and observe the documented flag set; malformed or missing required
> flags are rejected by `optparse-applicative` before any I/O; invoking
> the subcommand with valid flags surfaces the typed `TODO Slice C`
> error and exits non-zero. That is all.

## Upstream parity reference

The upstream bash
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
takes the same operator inputs every other treasury action takes:
funding seed UTxO, wallet address, scope name, metadata path, an
optional validity-hours, rationale overrides. This slice ships the
**parser** surface for those inputs in the Haskell CLI. The runner
body that maps inputs → chain queries → intent JSON belongs to #187.

| Bash phase | This slice covers? | Notes |
|---|---|---|
| `parse_cli` / opt-parsing | **yes** | optparse-applicative parser, typed `Answers` record, parser-level validators |
| `load_metadata` / `load_treasury_config` | no — wizard #187 | reads metadata + verifies registry |
| `build_signers $metadata $scope` | no — wizard #187 | resolves scope owner key hash |
| `resolve_fuel` | no — wizard #187 | picks the wallet UTxO from chain |
| `select_treasury_utxos` | no — wizard #187 | "compress until full" iteration |
| `compute_validity_period` | no — wizard #187 | samples tip + adds `--validity-hours` |
| `make_redeemer_reorganize` | no — already library (#185) | `Amaru.Treasury.Redeemer.reorganizeRedeemer` |
| `build_transaction` | no — already library (#185) | `runReorganizeBuild` |
| intent JSON encode + write to `--out` | no — wizard #187 | runner body |

The "parser scaffold" boundary is therefore: **expose the
optparse-applicative subcommand, validate the flag set at parse
time, validate `--out`'s parent directory exists before any work,
and dispatch to a typed TODO-stub runner**.

## User Scenarios & Testing

### User Story 1 — `reorganize-wizard --help` lists the documented flag set (Priority: P1)

**As an operator preparing a treasury reorganize transaction on a
local DevNet**, I run

```bash
amaru-treasury-tx reorganize-wizard --help
```

and observe the documented flag set — required and optional — without
the CLI making any chain query, file-system mutation, or network
call. I read the help text and decide which flags I need to supply
for my reorganize run.

**Why this priority**: this IS the parent epic #189 P1 contract for
this child. The shipped command surface is the operator-recovery
proof; without `--help` listing the flags, an operator cannot
discover the parser shape from the binary alone. Every sibling
wizard followed the same "Slice 1: parser scaffold" pattern.

**Independent Test**: spawn the built executable as a subprocess,
pass `reorganize-wizard --help`, capture stdout, assert that each
documented flag name (`--funding-seed-txin`, `--metadata`,
`--wallet-addr`, `--out`, `--network`, plus the sibling-mirrored
shared flags) is present in the help output. Exit code is 0.
No chain, no DevNet, no file I/O beyond the test's own stdout
capture.

**Acceptance Scenarios**:

1. **Given** the built `amaru-treasury-tx` executable, **When**
   `amaru-treasury-tx reorganize-wizard --help` runs, **Then** stdout
   lists every required flag (`--funding-seed-txin`, `--metadata`,
   `--wallet-addr`, `--out`, `--network`, and the sibling-mirrored
   shared flags settled in plan) and exits 0.
2. **Given** the built executable, **When**
   `amaru-treasury-tx --help` runs, **Then** the top-level subcommand
   listing includes `reorganize-wizard` with a one-line `progDesc`
   summary matching the sibling wizards' format.

---

### User Story 2 — malformed `--funding-seed-txin` is rejected at parse time (Priority: P1)

**As an operator**, when I mistype the funding seed TxIn (forgot the
`#`, used a non-hex character, used a 65-char prefix, used a 17-bit
index), the wizard rejects my command at parse time with a clear
typed error and exits non-zero **before** opening any node socket
or reading any registry file.

**Why this priority**: every sibling wizard mandates this exact
shape — the parser is the failure boundary for malformed
operator-typed values. The operator must see an error pointing at
the malformed flag, not a confusing stack trace from a chain client
called after parsing succeeded silently.

**Independent Test**: spawn the executable with a `--funding-seed-txin`
value that does not match `<txid64hex>#<word16>`, capture exit code
and stderr, assert exit code is non-zero (`optparse-applicative`
returns code 1 on parse errors), and the stderr names the offending
flag.

**Acceptance Scenarios**:

1. **Given** the executable, **When**
   `amaru-treasury-tx reorganize-wizard --funding-seed-txin "not-hex" ...`
   runs (other required flags supplied), **Then** the command exits
   non-zero, no chain query happens, no file is written to `--out`,
   and stderr names `--funding-seed-txin` or its `TXID#IX` metavar.
2. **Given** the executable, **When** the funding seed TxIn lacks
   the `#` separator, has a 63- or 65-char hex prefix, has a
   non-hex character, or has an index outside `0..65535`, **Then**
   the parser rejects each case with a typed error from
   `Amaru.Treasury.LedgerParse.txInFromText` (no hand-rolled parser).

---

### User Story 3 — missing required flag is rejected with a stable error (Priority: P1)

**As an operator**, when I forget `--metadata` or `--wallet-addr`,
the wizard rejects my command at parse time with
optparse-applicative's `missing required option` error and exits
non-zero before any I/O. (Issue #186's AC originally named
`--registry`; verdict α renamed it to `--metadata` for sibling
consistency — see Clarifications.)

**Why this priority**: required-flag enforcement is a parser
correctness invariant — silently defaulting any of these flags
would let the operator submit an under-specified intent. The
"missing required option" error is the standard `optparse-applicative`
shape every sibling wizard already produces.

**Independent Test**: spawn the executable with `--metadata`
omitted (otherwise valid flag set); assert exit code is non-zero
and stderr contains `Missing: --metadata`. Repeat with
`--wallet-addr` omitted.

**Acceptance Scenarios**:

1. **Given** the executable, **When** every required flag except
   `--metadata` is supplied, **Then** the parser exits non-zero
   and stderr contains a `Missing:` clause naming `--metadata`
   (the exact wording matches `optparse-applicative` defaults).
2. **Given** the executable, **When** every required flag except
   `--wallet-addr` is supplied, **Then** the parser exits non-zero
   and stderr contains a `Missing:` clause naming `--wallet-addr`.
3. **Given** the executable, **When** every required flag except
   `--funding-seed-txin` is supplied, **Then** the parser exits
   non-zero and stderr contains a `Missing:` clause naming
   `--funding-seed-txin`.
4. **Given** the executable, **When** every required flag except
   `--out` is supplied, **Then** the parser exits non-zero and
   stderr contains a `Missing:` clause naming `--out`.

---

### User Story 4 — `--out` parent directory missing surfaces typed error before work (Priority: P1)

**As an operator**, when I point `--out` at a path whose parent
directory does not exist (typo in the run directory), the wizard
surfaces a typed `ReorganizeError` to stderr and exits non-zero
**before** opening a node socket, reading the registry, or doing
any chain query. The typed error is structurally inspectable from
the test suite (no stderr regex matching).

**Why this priority**: matches the
`Amaru.Treasury.Cli.RegistryInitWizard.validateOutPath` pre-flight
behavior every sibling wizard already ships. Catches operator
typos at the cheapest stage and yields a typed error the smoke
layer can later assert on.

**Independent Test**: invoke the wizard with `--out` pointing at
`/nonexistent-parent/foo.json`, expect a typed
`ReorganizeOutputParentMissing _` error printed to stderr and
exit code 2 (matching the sibling pre-flight exit code), and
assert no node socket was opened (no `--node-socket` env / arg
needed in the test, since the pre-flight precedes socket setup).

**Acceptance Scenarios**:

1. **Given** the executable and a `--out` argument
   `/tmp/this-dir-does-not-exist-186/foo.json` whose parent is
   absent, **When** the wizard runs with otherwise valid flags,
   **Then** the wizard exits non-zero with stderr naming
   `ReorganizeOutputParentMissing "/tmp/this-dir-does-not-exist-186"`
   (the typed error's `Show` instance), no socket is opened, no
   file is written.
2. **Given** an `--out` argument whose parent directory exists,
   **When** the wizard runs with otherwise valid flags, **Then**
   the pre-flight passes; the runner stub then fires the typed
   `ReorganizeTodoSliceC` (or equivalently-named) error from
   FR-006 — proving the pre-flight ran *before* the stub.

---

### User Story 5 — `--network` other than `devnet` is rejected before any chain query, file write, or socket open (Priority: P1)

**As an operator**, when I accidentally point `--network` at
`preprod` or `mainnet`, the wizard refuses to even build the intent
— this slice's runner pre-flight rejects any non-`devnet` value
before any chain query, file write, or socket open, mirroring the
upstream `reorganize-wizard --network devnet` invariant the
parent epic calls out under "Network safety is fail-closed".

(Q-001-C verdict: refined to C2 at plan time. The check lives in
the runner pre-flight rather than a parser-time custom `ReadM`
because `--network` is owned by the global parser
`Amaru.Treasury.Cli.Common.globalOptsP`; a wizard-subcommand flag
would shadow it. The pre-flight runs before any chain query, file
write, or socket open — observationally identical to a parse-time
rejection for the operator. See plan.md and research.md §5.)

**Why this priority**: parent-epic carry-forward invariant. Without
network safety enforced before any work happens, an operator could
build a reorganize intent that names a mainnet treasury address
and not discover the mistake until much later. The runner body
(#187) will re-validate, but this slice's pre-flight must already
fail closed.

**Independent Test**: invoke the wizard with `--network preprod`
(or `mainnet`), assert exit code is non-zero (2), stderr names
the typed `ReorganizeNonDevnetNetwork` error, no chain query was
attempted, no file was written. Repeat for `mainnet` and
`preview`.

**Acceptance Scenarios**:

1. **Given** the executable, **When** the operator passes
   `--network preprod`, **Then** the wizard rejects before any
   chain query, file write, or socket open; exits with code 2;
   stderr contains `ReorganizeNonDevnetNetwork "preprod"`.
2. **Given** the executable, **When** the operator passes
   `--network mainnet`, **Then** the wizard rejects identically
   with `ReorganizeNonDevnetNetwork "mainnet"`.
3. **Given** the executable, **When** the operator passes
   `--network devnet`, **Then** the pre-flight accepts the value;
   the runner stub fires the typed `ReorganizeTodoSliceC` error
   downstream — proving the pre-flight check accepted the only
   allowed value.

---

### Edge Cases

- **Empty flag set** (`amaru-treasury-tx reorganize-wizard` with no
  arguments at all): `optparse-applicative` lists every missing
  required option in a single error block; the parser is
  expected to behave identically to sibling wizards and exit
  non-zero. The test suite need not enumerate all missing flags;
  a single representative case (User Story 3) suffices.
- **`--funding-seed-txin` index `65535`** (Word16 maximum): the
  shared `txInFromText` parser already accepts this; the new
  parser must too. **`--funding-seed-txin` index `65536`** (out
  of Word16 range): the shared parser rejects; the new parser
  must propagate the rejection.
- **`--out` points at an existing file** without `--force`: this
  slice MAY mirror the sibling `RegistryInitOutputExistsNoForce`
  shape, or MAY defer it to #187. The plan picks one (the
  sibling pattern is the obvious default).
- **`--scope` value not in the documented enum**: this slice MAY
  carry `--scope` as a required flag (matching every other
  wizard) and reuse the shared `scopeFromText` reader, which
  rejects unknown values at parse time. The plan picks the
  exact flag inventory based on what `ReorganizeInputs` (already
  shipped in #185) needs from the operator.
- **`--node-socket` / `CARDANO_NODE_SOCKET_PATH` absent**: this
  slice does NOT open the socket (the stub runner exits before
  that), so the absent-socket case does not appear here; #187
  inherits the existing
  `--node-socket / CARDANO_NODE_SOCKET_PATH is required` shape.
- **`--help` printed when `--network mainnet` is the **only**
  argument**: `optparse-applicative` prefers the `--help` flag
  when both `--help` and an erroring argument are present
  (default behavior). This slice does NOT customize that; the
  test suite need not pin it.

## Requirements

### Functional Requirements

- **FR-001**: `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (new module)
  MUST expose an `optparse-applicative` `Parser` named
  `reorganizeWizardOptsP :: Parser ReorganizeWizardOpts` that
  defines the documented flag set.
- **FR-002**: `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (new
  module) MUST expose:
  - the typed answers record `data ReorganizeWizardAnswers = ...`
    carrying every operator-typed value the parser collects
    (final field set settled in plan; minimum: funding seed TxIn,
    wallet address, scope, `--out` path, rationale overrides);
  - the typed error sum `data ReorganizeError = ...` with at
    least the variants `ReorganizeOutputParentMissing FilePath`,
    `ReorganizeOutputExistsNoForce FilePath` (or its plan-time
    equivalent if the slice opts to defer `--force` to #187),
    and `ReorganizeTodoSliceC` (the runner-stub marker — exact
    constructor name picked in plan but MUST be recognisable as
    "TODO for the wizard runner slice").
- **FR-003**: `lib/Amaru/Treasury/Cli.hs` MUST add a
  `CmdReorganizeWizard ReorganizeWizardOpts` constructor to the
  top-level `Cmd` sum AND wire a `command "reorganize-wizard"`
  entry into `cmdP`, with a one-line `progDesc` matching the
  sibling wizards' format.
- **FR-004**: `app/amaru-treasury-tx/Main.hs` MUST dispatch
  `CmdReorganizeWizard` to `runReorganizeWizard` from the new
  CLI module.
- **FR-005**: `runReorganizeWizard :: GlobalOpts ->
  ReorganizeWizardOpts -> IO ()` MUST:
  - run the `--out` parent-directory pre-flight check (mirroring
    `validateOutPath`) before any chain query or socket open;
  - on pre-flight failure, print the typed `ReorganizeError` to
    stderr and exit with code 2 (matching the sibling
    `validateOutPath` failure path);
  - on pre-flight success, fire the typed
    `ReorganizeTodoSliceC` (or equivalent) error to stderr and
    exit with code 3, naming "TODO Slice C — wizard runner
    body lands in #187".
- **FR-006**: The parser MUST reuse
  `Amaru.Treasury.LedgerParse.txInFromText` via
  `Options.Applicative.eitherReader` for the
  `--funding-seed-txin` flag. No hand-rolled `txid#ix` parser.
- **FR-007**: The runner pre-flight MUST reject `--network`
  values other than `"devnet"` before any chain query, file write,
  or socket open. The check is implemented in
  `runReorganizeWizardEither` (`Amaru.Treasury.Cli.ReorganizeWizard`)
  and surfaces a typed `ReorganizeNonDevnetNetwork Text` error at
  exit code 2. The check lives at the pre-flight tier rather than
  as a parser-time custom `ReadM` because `--network` is owned by
  the global parser `Amaru.Treasury.Cli.Common.globalOptsP`; a
  wizard-subcommand `--network` flag would shadow / conflict with
  the global flag. (Q-001-C verdict: refined to C2 at plan time —
  see plan.md and research.md §5.) The acceptance shape (User
  Story 5) is preserved: no chain query, no file write, no socket
  open, stderr names the typed error.
- **FR-008**: Every required flag MUST be marked required in the
  parser (no `optional` wrapper, no `value` default).
- **FR-009**: `amaru-treasury-tx.cabal` MUST expose
  `Amaru.Treasury.Cli.ReorganizeWizard` and
  `Amaru.Treasury.Tx.ReorganizeWizard` in the `library` stanza's
  `exposed-modules` list.
- **FR-010**: New parser tests under
  `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`
  MUST cover, at minimum, the five User Story 1–5 acceptance
  shapes. The tests MUST drive
  `reorganizeWizardOptsP` via `Options.Applicative.execParserPure`
  (no subprocess spawning required; mirrors the existing parser
  tests for sibling wizards).
- **FR-011**: `nix build .#checks.unit` MUST pass at HEAD. Every
  commit on `186-reorganize-wizard-parser` MUST pass `./gate.sh`
  (build + unit + golden + format + hlint + Conventional Commits
  + `Tasks:` trailer).
- **FR-012**: This slice MUST NOT touch
  `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`, or
  `lib/Amaru/Treasury/Build.hs` — those are owned by the
  already-merged #185 library core. The build path is reused
  verbatim from #185 once #187 wires the runner.

### Non-Functional Requirements

- **NFR-001**: This slice introduces NO chain client work, NO
  registry verification, NO UTxO selection, NO validity-bound
  computation, NO intent encoding. Those belong to #187.
- **NFR-002**: This slice introduces NO docs / README / asciinema
  changes. Those belong to #188.
- **NFR-003**: This slice introduces NO new dependencies in
  `amaru-treasury-tx.cabal`. Everything used (`optparse-applicative`,
  `cardano-ledger-conway`, the shared `LedgerParse` helpers) is
  already present.
- **NFR-004**: Library + CLI-only behavior changes are bisect-safe.
  Every commit on the branch compiles; every commit's `./gate.sh`
  is green.

### Key Entities

- **`ReorganizeWizardOpts`** (in
  `Amaru.Treasury.Cli.ReorganizeWizard`): the optparse-applicative
  output record. Carries every operator-typed flag value at the
  CLI surface. May be either flat (one record per parser) or
  layered (`CommonFlags` + `ReorganizeWizardOpts` shape, matching
  sibling wizards' `CommonFlags`). Plan picks; sibling-mirror is
  the default.
- **`ReorganizeWizardAnswers`** (in
  `Amaru.Treasury.Tx.ReorganizeWizard`): the typed answers record
  the runner consumes — the "interview answers" view of
  `ReorganizeWizardOpts`. Mirrors
  `RegistryInitSeedSplitAnswers` / `WithdrawAnswers` / etc.
  Carries the same fields; the `Opts` → `Answers` projection
  lives in the runner module so the parser stays Cli-only and
  the runner stays Tx-only (sibling convention).
- **`ReorganizeError`** (in
  `Amaru.Treasury.Tx.ReorganizeWizard`): the typed error sum
  surfaced by the runner. At minimum the pre-flight failure
  variants (`ReorganizeOutputParentMissing FilePath`,
  optionally `ReorganizeOutputExistsNoForce FilePath`) and the
  `ReorganizeTodoSliceC` (or plan-time equivalent) stub
  variant. #187 grows this type with the runner-body error
  variants.

## Deliverables

| Artifact | Purpose | Surfaces touched | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` | parser + stub runner + `--out` pre-flight | `library` stanza | yes — new module |
| `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` | typed `Answers` record + `ReorganizeError` sum | `library` stanza | yes — new module |
| `lib/Amaru/Treasury/Cli.hs` | `CmdReorganizeWizard` arm + `command "reorganize-wizard"` entry | `library` stanza | yes — extend |
| `app/amaru-treasury-tx/Main.hs` | dispatch `CmdReorganizeWizard` to `runReorganizeWizard` | `executable amaru-treasury-tx` | yes — extend |
| `amaru-treasury-tx.cabal` | expose the two new modules | `library` stanza | yes |
| `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` | parser tests for User Story 1–5 acceptance shapes | `test-suite unit-tests` | yes — new |

This slice does **not** ship:

- live chain query / treasury UTxO selection / validity-bound
  sampling / intent encoding / file write (#187)
- DevNet smoke (#87)
- README / `docs/...` updates, asciinema cast (#188)
- changes to the library-core reorganize build path (already
  shipped in #185)
- changes to `docs/assets/intent-schema.json` (the schema is
  fixed by #185; this slice adds no new arm)

**Asciinema scope clarification**: the parent epic #189 calls out
`docs/assets/asciinema/reorganize.cast` as a first-class deliverable
for the operator surface. The cast is recorded **after** #187's
runner is functional; recording a cast against a stub runner that
only emits "TODO Slice C" carries no operator value. The cast and
prose docs are explicitly owned by #188 and gated on #187's merge.
This is consistent with the resolve-ticket vertical-deliverables
rule because the peer surface in this slice is the **parser
scaffold + parser tests**, not a usable operator command; the
usable operator command lives at #187, where the cast follows in
#188.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx reorganize-wizard --help` exits 0
  and stdout lists every flag named in the parser tests
  (`--funding-seed-txin`, `--metadata`, `--wallet-addr`, `--out`,
  `--network`, plus the sibling-mirrored shared flags settled in
  plan).
- **SC-002**: Invoking `amaru-treasury-tx reorganize-wizard` with a
  malformed `--funding-seed-txin` value exits non-zero and stderr
  names the offending flag. The parser tests assert this via
  `Options.Applicative.execParserPure` (`Failure` constructor with
  the expected message), not a subprocess regex.
- **SC-003**: Invoking the wizard with any of `--funding-seed-txin`,
  `--metadata`, `--wallet-addr`, `--out` omitted exits non-zero with
  a `Missing:` clause naming the omitted flag.
- **SC-004**: Invoking the wizard with `--out
  /tmp/<nonexistent>/foo.json` exits with code 2 and stderr names
  `ReorganizeOutputParentMissing` (the typed error's `Show`
  instance). No socket is opened.
- **SC-005**: Invoking the wizard with `--network preprod` (or
  `mainnet`) exits non-zero before any chain query, file write,
  or socket open; stderr names the typed
  `ReorganizeNonDevnetNetwork` error. With `--network devnet` and a valid `--out` path,
  the runner stub fires `ReorganizeTodoSliceC` (or its plan-time
  equivalent) and exits non-zero.
- **SC-006**: `grep -nE 'funding-seed-txin' lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`
  matches at least once; `grep -nE 'eitherReader \(txInFromText'
  lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` matches (the parser
  reuses the shared reader) AND
  `grep -nE 'parseTxIn|parseTxin|splitTxin' lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`
  returns zero hits (no hand-rolled parser).
- **SC-007**: `nix build .#checks.unit` and `./gate.sh` are green
  at HEAD when the PR is marked ready.
- **SC-008**: Every commit on `186-reorganize-wizard-parser`
  carries a Conventional Commits subject and a `Tasks: T###[, T###]`
  trailer (enforced by `./gate.sh`).

## Command-Recovery Posture

This slice ships an operator-facing command surface:
`amaru-treasury-tx reorganize-wizard <flags>`. The command is
**not yet functional** — it parses, validates, and exits with a
typed TODO error. The shipped command's `--help` IS the operator
recovery proof for this slice (User Story 1). The functional
recovery (parse → resolve → write intent.json) is shipped by #187;
the live DevNet smoke is shipped by #87.

`tx-build --intent` already accepts a reorganize intent JSON (wired
by #185's dispatcher arm). After #187 lands, an operator runs

```bash
amaru-treasury-tx --network devnet reorganize-wizard \
  --metadata <metadata.json> \
  --wallet-addr <bech32> \
  --funding-seed-txin <txid64hex>#<word16> \
  --scope <name> \
  --out reorganize-intent.json \
  [--validity-hours <hours>] \
  [--description ...] \
  [--justification ...] \
  ...

amaru-treasury-tx tx-build --intent reorganize-intent.json --out tx.unsigned.cbor
```

to produce an unsigned Conway tx. This slice only ships the first
command's parser surface; the second command already works.

## Clarifications

### Resolved clarifications (Q-001-spec-ready @ A-001, Q-002-plan-ready @ A-002)

Three design choices opened at Q-001-spec-ready. Verdicts
approved at A-001 + A-002:

- **A → A1 (chosen)**: `--scope` is a required CLI flag at the
  parser, reusing the shared `scopeReader`. Sibling-mirror.
- **B → B1 (chosen)**: the parser exposes the full
  sibling-mirrored shared flag block (`--description`,
  `--justification`, `--destination-label`, `--event`, `--label`,
  `--validity-hours`, `--metadata`, `--force`) alongside the
  reorganize-specific `--funding-seed-txin`. Parser tests cover
  only the issue-enumerated five.
- **C → C2 (refined from C1 at plan time)**: the `--network
  devnet` check lives in the **runner pre-flight** (in
  `runReorganizeWizardEither`), not in a parser-time custom
  `ReadM`. C1 was architecturally infeasible because `--network`
  is owned by the global parser
  `Amaru.Treasury.Cli.Common.globalOptsP`; a wizard-subcommand
  flag would shadow / conflict with the global flag. The C2
  pre-flight runs before any chain query, file write, or socket
  open — observationally identical to a parse-time rejection
  from the operator's perspective. See plan.md and research.md
  §5.

**Q-001 verdict α — `--registry` flag name amended to
`--metadata`**: issue #186's ACs use the flag name `--registry`.
Every sibling wizard uses `--metadata` (path to
`journal/2026/metadata.json`). Verdict α (approved at A-002)
ships the sibling-mirrored `--metadata` flag. This spec amends
User Story 3's heading + Independent Test + Acceptance Scenarios
1 & 2, User Story 1's flag inventory, SC-001's and SC-003's flag
lists, and the Command-Recovery Posture's example invocation to
use `--metadata`. User Story 3 keeps a "(Issue #186's AC
originally named `--registry`; verdict α renamed it to
`--metadata` for sibling consistency)" gloss so a reader can
trace back to the issue text. See analysis.md §3.2.

### Original clarification text (preserved for context)

The five User Stories above are tight on parser behavior (they
re-state the issue's ACs in given/when/then form). Three design
choices were flagged at spec time:

- **Q-001-A: `--scope` as a required CLI flag?** Every sibling
  wizard takes `--scope` as a required flag (the `scopeReader` is
  shared in `Amaru.Treasury.Cli.RegistryInitWizard`). Reorganize is
  per-scope upstream (one scope per invocation, mirroring
  `reorganize.sh`). The strong default is YES — `--scope` is
  required at the parser, reusing the shared `scopeReader`.
  - **Recommended verdict A1**: ship `--scope` as a required flag,
    mirroring siblings.
  - Alternative A2: defer `--scope` to #187 if there is some
    upstream parity reason I have missed (no signal in the issue
    or #185 spec suggests this).

- **Q-001-B: Shared rationale flags / `--validity-hours` / `--metadata`
  / `--force` in this scaffold?** Every sibling wizard exposes
  `--description`, `--justification`, `--destination-label`,
  `--event`, `--label` (rationale overrides),
  `--validity-hours`, `--metadata`, and `--force`. The issue's ACs
  enumerate only `--funding-seed-txin`, `--registry`, `--wallet-addr`,
  `--out`, `--network`. The strong default is to expose the
  sibling-mirrored shared flags here too — the parser surface is
  thrown away if #187 has to widen it — but the tests only need to
  cover what the issue enumerates (the wider flag set is internally
  consistent with siblings, not new functional requirements).
  - **Recommended verdict B1**: include the sibling-mirrored shared
    flags now (rationale overrides + `--validity-hours` +
    `--metadata` + `--force`); parser tests cover only the
    explicitly enumerated five.
  - Alternative B2: ship only the five flags enumerated in the
    issue; widen later in #187. Trades a slightly tighter slice
    boundary for visible churn in the next slice.

- **Q-001-C: Where does the `--network devnet` check live?** Two
  candidate placements:
  - **Recommended verdict C1**: parse-time custom `ReadM` that
    rejects non-`devnet` values directly in
    `reorganizeWizardOptsP`. Cleanest mapping to User Story 5's
    "rejected at the parser" wording.
  - Alternative C2: parse-time accept any network name, post-parse
    fail-closed inside the `--out` pre-flight (before any chain
    query). Slightly weaker — the failure surfaces from the runner
    pre-flight, not from the parser itself. The User Story 5
    wording would need a minor edit ("rejected before any work
    happens" rather than "rejected at the parser"). User Story 5
    is currently aligned with C1; if the epic owner picks C2 the
    spec/test wording is amended in plan.

These three questions are non-blocking for understanding (the
issue's ACs are unambiguous on the five-flag minimum) but they
DO shape the parser shape the plan sketches. Plan can pick the
recommended verdicts as the default if the epic owner approves
the spec as-is.

## Non-Goals

- Wizard runner body (chain query, registry verification, UTxO
  selection, validity sampling, intent encoding, file write) —
  #187.
- DevNet smoke that drives the shipped CLI against a live chain —
  #87.
- README / `docs/...` updates, asciinema cast — #188.
- Multi-scope reorganize.
- Changes to `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`, or
  `lib/Amaru/Treasury/Build.hs` — already shipped in #185.
- New library functions in `Amaru.Treasury.LedgerParse` (the
  parser reuses the existing `txInFromText`).
- Touching `docs/assets/intent-schema.json` (already shipped in
  #185).

## Parent Carry-Forward Invariants

From epic #189, every child carries these invariants; #186
inherits them with these specific instantiations:

- **Reorganize tx is the simplest of the three operational actions**:
  reflected in the parser surface — no beneficiary flag, no unit
  branching, no `--amount` (the "compress until full" iteration
  in #187 removes the need for an explicit amount; see #185
  spec's "Operational model carry-forward").
- **Construction lives in production library code, never in smoke
  specs.** Reflected here: the parser produces an `Opts` record
  whose runner (#187) calls into `Amaru.Treasury.Build.Reorganize`
  (already shipped in #185). Parser tests use
  `execParserPure` only — no smoke spec extension.
- **Shipped CLI surface produces unsigned txs only.** This slice
  produces no tx at all (the runner is stubbed); the next slice
  (#187) wires the runner to call `runReorganizeBuild`, which
  produces unsigned Conway CBOR. The CLI never signs.
- **Network safety is fail-closed.** Enforced here by User Story
  5 + FR-007.
- **Operator-typed inter-tx values.** The parser collects the
  funding seed TxIn (operator-typed); the rest of the inter-tx
  values (treasury UTxOs, validity bound, deployed-script refs,
  signers) are wizard-resolver-derived in #187, not operator-typed.
- **Phase-1 validation includes execution units.** Not exercised
  in this slice (no tx is built); #87's live smoke is where
  exec-units coverage lands.

## Assumptions

- The shared
  `Amaru.Treasury.LedgerParse.txInFromText` parser already
  accepts the exact `<txid64hex>#<word16>` format the issue calls
  out — verified empirically by every sibling wizard's
  `txInReader`.
- The shared `Amaru.Treasury.Cli.Common.scopeReader`
  (or its equivalent) already accepts the scope-name vocabulary
  reorganize needs. If reorganize needs a scope name outside the
  existing enum, that is plan-time discovery and lands as a
  separate ticket (not silently widened in this slice).
- `optparse-applicative`'s `Missing:` error message wording is
  stable across the versions pinned in the haskell.nix project
  set — sibling wizards' parser tests already depend on it.
- The exit code convention `(0 = ok, 1 = parse error, 2 =
  pre-flight error, 3 = runner error)` matches the sibling
  wizards. The runner-stub error in this slice exits with code
  3 (the same code #187's real runner will use for typed errors).
- `nix build .#checks.unit` is the canonical unit-test runner
  for this PR (parser tests live under
  `test-suite unit-tests` per the existing cabal file).
- The plan picks the exact placement of the typed `Answers`
  record / `ReorganizeError` sum (sibling convention is
  "answers + errors live in `Tx/<Name>Wizard.hs`, parser +
  runner shell live in `Cli/<Name>Wizard.hs`"). This spec does
  not pin module-internal naming.
