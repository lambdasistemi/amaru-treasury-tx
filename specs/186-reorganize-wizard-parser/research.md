# Research — `186-reorganize-wizard-parser`

## Scope

This document captures the design decisions, alternatives,
rejected paths, and plan-time discoveries for the parser
scaffold slice. The companion `plan.md` references each entry
where appropriate.

## 1. Sibling parser-scaffold pattern (basis)

**Decision**: replicate the
`Amaru.Treasury.Cli.RegistryInitWizard` parser layout exactly:

- `Cli/<Name>Wizard.hs` owns the parser, the option records,
  the `ReadM` helpers, the `validateOutPath` pre-flight, and
  the top-level `runWizard` dispatcher.
- `Tx/<Name>Wizard.hs` owns the typed `Answers` records (one
  per sub-action), the `ReorganizeError` sum, and the
  pure runner/resolver helpers (in this slice, only the
  `Answers` record + error type — the resolver lives at #187).

**Rationale**: every existing wizard follows this split. Future
maintainers grep for `<Name>Wizard.hs` and find one Cli file
plus one Tx file — predictable. Inconsistency with siblings
would force readers to learn a new convention per wizard.

**Alternatives considered**:

- **A1**: flat module `Amaru.Treasury.Cli.ReorganizeWizard.hs`
  containing everything (parser + types + runner stub) without
  a sibling `Tx/...Wizard.hs`. Rejected: the runner body in
  #187 will need the typed `Answers` shape from a location the
  next slice's tests can import without dragging in the parser.
  Mirrors the sibling split.
- **A2**: a single `Amaru.Treasury.Cli.ReorganizeWizard` module
  that internally re-exports types. Rejected: increases the
  module's surface area for no gain; sibling pattern is "Cli
  for parser+runner shell, Tx for typed answers+errors".

## 2. Reorganize has no sub-actions

**Decision**: the parser is a flat `Parser ReorganizeWizardOpts`
— no `hsubparser` for sub-actions. The wizard ships exactly one
operation.

**Rationale**: per parent epic #189's "architectural invariants"
block, "Reorganize tx is the simplest of the three operational
actions: single continuing output back to the same treasury
address; signed by scope owner only; no beneficiary, no unit
branching." Upstream
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
likewise has one entry point and no sub-action discriminator.
RegistryInit (4 sub-actions: seed-split, mint,
reference-scripts, write-artifacts), StakeRewardInit, and
GovernanceWithdrawalInit (each 2 sub-actions) all use
`hsubparser`; reorganize does not.

**Alternatives considered**:

- **B1**: introduce a single `command "reorganize"` sub-action
  under `reorganize-wizard` for future-proofing. Rejected: no
  forecasted second sub-action; YAGNI. The parser can be
  widened later by introducing `hsubparser` without breaking
  the existing flag set (the existing flags would migrate into
  a `CommonFlags` block, identical to RegistryInit's S1 → S3
  evolution).

## 3. Q-001-A — `--scope` as a required parser flag (verdict A1 confirmed)

**Decision**: `--scope` is a required flag at parse time, reusing
the shared `scopeReader` ReadM from sibling wizards.

**Rationale**: upstream bash `reorganize.sh` takes a `--scope`
argument; reorganize is per-scope (one scope per invocation).
Every sibling wizard takes `--scope` as required. The
`scopeReader` already accepts the documented vocabulary
(`core_development|ops_and_use_cases|network_compliance|middleware`)
and rejects unknown values at parse time.

**Where the reader lives**: in
`Amaru.Treasury.Cli.RegistryInitWizard.scopeReader` (currently
not exported). The slice executor will EITHER (a) re-define
`scopeReader` locally in
`Amaru.Treasury.Cli.ReorganizeWizard.hs`, mirroring the existing
pattern (each wizard owns its own copy — minor duplication that
matches sibling convention), OR (b) extract `scopeReader` into
`Amaru.Treasury.Cli.Common` and re-export. The slice executor
picks option (a) by default; option (b) would expand the slice
boundary into a shared-module refactor outside the brief.

## 4. Q-001-B — sibling-mirrored shared flags (verdict B1 confirmed)

**Decision**: the parser exposes the full sibling-mirrored shared
flag block:

- `--wallet-addr <BECH32>` (required)
- `--metadata <PATH>` (required — path to journal/2026 metadata)
- `--out <PATH>` (required, with `-o` short alias)
- `--log <PATH>` (optional)
- `--scope <NAME>` (required, per A1)
- `--validity-hours <HOURS>` (optional)
- `--description <TEXT>` (optional rationale override)
- `--justification <TEXT>` (optional rationale override)
- `--destination-label <TEXT>` (optional rationale override)
- `--event <TEXT>` (optional rationale override)
- `--label <TEXT>` (optional rationale override)
- `--force` (boolean flag, defaults False)

Plus the reorganize-specific:

- `--funding-seed-txin <TXID#IX>` (required)

Plus the C2-tier network safeguard (no parser flag — see §5).

**Rationale**: B1's case carries no observable behavior change
for the parser tests (which only assert the issue-enumerated
five), but ships a parser surface coherent with the next
slice's runner. Without these flags, #187 would have to widen
the parser surface — adding visible churn between slices and
making bisect harder.

**Alternatives considered**:

- **B2 (rejected)**: ship only the issue-enumerated five flags;
  widen at #187. Trades a slightly tighter slice boundary for
  the visible churn cost above.

## 5. Q-001-C1 → C2 plan-time discovery

**Decision**: refine Q-001-C from C1 ("parser-time custom `ReadM`
in `reorganizeWizardOptsP`") to **C2** ("pre-flight runner
check, before any chain query / file write / socket open").

**Why C1 is architecturally infeasible**:

The `--network` flag is owned by the **global** parser
`Amaru.Treasury.Cli.Common.globalOptsP` (lines 69–109 of
`lib/Amaru/Treasury/Cli/Common.hs`). The global parser exposes
`--network NAME` where `NAME ∈ {mainnet, preprod, preview,
devnet}` via the `networkNameToPair` `eitherReader`. The
top-level parser combines globalOpts + cmdP at
`lib/Amaru/Treasury/Cli.hs` lines 313–316:

```haskell
opts :: ParserInfo (GlobalOpts, Cmd)
opts = info ... (((,) <$> globalOptsP <*> cmdP) <**> helper) ...
```

If the wizard subcommand parser
(`reorganizeWizardOptsP`) also declared a `--network` flag, the
flag would be consumed by whichever parser optparse-applicative
runs first. In practice the global parser runs first; the
wizard parser would then either:

- Require the user to pass `--network` **twice** (once globally,
  once to the subcommand) — ugly and confusing.
- Be unable to see `--network` at all (the global parser
  already consumed it).

The only way to make C1 work would be to add a wizard-only
flag with a *different name* (e.g., `--devnet-only`), which
would diverge from the issue AC's explicit wording
(`--network other than devnet is rejected`).

**Why C2 satisfies the issue AC**: User Story 5's intent is
"`--network preprod` (or `mainnet`/`preview`) fails before any
chain query, file write, or socket open". A pre-flight check
in `runReorganizeWizard` — placed BEFORE `validateOutPath`,
BEFORE any node socket open, BEFORE any chain query — reads
`resolveNetworkName globalOpts` and rejects non-`devnet`
values with a typed `ReorganizeNonDevnetNetwork Text` error,
exit code 2 (same tier as `ReorganizeOutputParentMissing`).
From the operator's perspective:

```
$ amaru-treasury-tx --network preprod reorganize-wizard \
    --funding-seed-txin <valid> ... --out /tmp/foo.json
ReorganizeNonDevnetNetwork "preprod"
$ echo $?
2
```

— observationally indistinguishable from a parse-time
rejection.

**Spec amendment required**: `spec.md` User Story 5 and FR-007
say "rejected at the parser". The wording needs amendment to
"rejected before any chain query, file write, or socket open"
(or equivalent). Captured as **task T015** in `tasks.md`
shipped via the `docs(spec):` commit in S3.

**Sibling precedent**: `Amaru.Treasury.Cli.RegistryInitWizard`
implements the devnet-only check at the resolver tier (lines
857–865 of the file:
`case networkName of "devnet" -> pure () ; other -> abort`).
The corresponding test spec
`Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec`
exercises this at the resolver layer. The reorganize-wizard
mirrors this exact pattern; the C2 implementation is
literally the sibling pattern.

**Q-002-plan-ready surfaces this** for the epic-owner's read
receipt. Autonomous-drive default: proceed with C2 because C1
is architecturally infeasible.

## 6. Test architecture — `execParserPure` plus typed-error capture

**Decision**:

- User Stories 1, 2, 3 — `execParserPure reorganizeWizardOptsP
  <argv>` returns `Success ReorganizeWizardOpts | Failure
  ParserFailure`; the test inspects the `Failure` for the
  expected error text (`Missing: ...`, `Invalid option ...`).
- User Story 4 — `validateOutPath path force` returns
  `IO (Either ReorganizeError ())`. The test calls this
  directly, no parser involved, no `try` needed.
- User Story 5 — `runReorganizeWizard g opts` is `IO ()` that
  ultimately calls `exitWith (ExitFailure 2)` for the
  non-devnet case. The test intercepts the exit via either:
  - `Control.Exception.try @System.Exit.ExitCode`, which
    catches the `ExitException` thrown by `exitWith`, OR
  - a helper `runReorganizeWizardEither :: GlobalOpts ->
    ReorganizeWizardOpts -> IO (Either ReorganizeError ())`
    that does NOT call `exitWith`, returning the typed error
    instead. `runReorganizeWizard` becomes the
    `exitWith`-on-error shim around it.

  The second form is cleaner and aligns with sibling pattern
  (`validateOutPath` already returns `Either`). The S1 brief
  instructs the slice executor to introduce a
  `runReorganizeWizardEither` (or an equivalently-named helper)
  for testability.

**Rationale**: subprocess-based tests are slow, fragile, and
require an installed binary. Sibling parser specs use
`execParserPure` and direct library calls; this slice does
the same.

## 7. Stub runner exit-code convention

**Decision**: mirror the sibling exit-code convention:

- **0** — `--help` printed, no work.
- **1** — `optparse-applicative` parse failure (handled by
  the framework).
- **2** — typed pre-flight error (`ReorganizeOutputParentMissing`,
  `ReorganizeOutputExistsNoForce`, `ReorganizeNonDevnetNetwork`).
- **3** — runner error (in this slice: only
  `ReorganizeTodoSliceC`).

This mirrors `Amaru.Treasury.Cli.RegistryInitWizard`'s
`exitWith (ExitFailure 2)` for pre-flight and `(ExitFailure 3)`
for runner errors.

## 8. Stub-runner naming — `ReorganizeTodoSliceC`

**Decision**: name the runner-stub variant `ReorganizeTodoSliceC`
of the `ReorganizeError` sum.

**Rationale**: `Slice C` is the name #187's plan/tasks will
use for the live-runner-body slice (per epic #189's child
sequencing — A = #185 library core, B = #186 parser scaffold,
C = #187 runner body). The `Slice C` naming makes the dependency
explicit when an operator (or a curious grep) sees the stub
error; the next slice's `chore: drop ReorganizeTodoSliceC` is
self-documenting.

**Alternatives considered**:

- `ReorganizeRunnerNotYetWired` — too verbose, less specific
  to the ticket sequence.
- `ReorganizeTodo187` — references the issue number, brittle
  against repo refactors / cross-repo issue moves.
- `ReorganizeUnimplemented` — too vague.

## 9. Why no `Amaru.Treasury.IntentJSON` changes

**Decision**: this slice does NOT touch
`lib/Amaru/Treasury/IntentJSON.hs`.

**Rationale**: #185's library core (merged at `da9d65b5`)
already shipped the `ReorganizeInputs` JSON shape, the
`translateIntent SReorganize` arm, and the
`docs/assets/intent-schema.json` schema. This slice ships only
the CLI scaffold; the runner body in #187 will be the consumer
of these existing library shapes.

## 10. Cabal exposure ordering

**Decision**: insert `Amaru.Treasury.Cli.ReorganizeWizard` and
`Amaru.Treasury.Tx.ReorganizeWizard` into the cabal `library`
stanza's `exposed-modules` list in alphabetical order
(matching existing convention).

`grep -nE 'Amaru.Treasury.(Cli|Tx).(R|S|W)' amaru-treasury-tx.cabal`
will show the slice executor exactly where each module
belongs.

## 11. Risks summary (informational; mitigations in `plan.md`)

- **R1**: Q-001-C1 → C2 spec amendment (documented in S3).
- **R2**: capturing `exitWith` from the runner stub in tests
  (resolved by the `runReorganizeWizardEither` helper above).
- **R3**: `optparse-applicative` version drift (parser tests
  assert substring containment, not exact strings).
- **R4**: `--metadata` flag tension (verdict B1 ships it; the
  parser tests don't enumerate it).
- **R5**: pre-flight ordering (`--network` check first, then
  `validateOutPath`, then stub) — documented in
  [`contracts/exit-code-contract.md`](./contracts/exit-code-contract.md).
