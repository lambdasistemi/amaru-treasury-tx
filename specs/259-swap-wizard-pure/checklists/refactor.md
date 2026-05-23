# Refactor Quality Checklist: Swap wizard pure intent producer

**Purpose**: Validate that the spec captures, with enough rigor to prevent silent regression, the six refactor-critical invariants — byte-identity goldens, per-variant failure coverage, abort-site elimination, tracer-as-informational, concurrency model, and CLI exit-code mapping.
**Created**: 2026-05-23
**Feature**: [spec.md](../spec.md)

## Byte-identity goldens

- [ ] CHK001 Is the exact set of golden fixtures (paths under `test/`) named in requirements, rather than referenced as "the test corpus"? [Completeness, Spec §FR-006, FR-007]
- [ ] CHK002 Is "byte-identical" defined to mean a `cmp`-level byte equality and not a semantic-equivalence rule that allows whitespace or field-order drift? [Clarity, Spec §FR-006, FR-007]
- [ ] CHK003 Are requirements written for both the function-level golden (calling `buildSwapIntent` / `buildSwapTx` from Hspec) and the CLI-level smoke (devnet recipe), so neither layer can silently drift? [Coverage, Spec §SC-001, SC-002]
- [ ] CHK004 Does the spec state how a newly-introduced failure path becomes a fixture — i.e., is the rule "every new `abortTr` removal adds a triggering fixture before merge" written down? [Gap]
- [ ] CHK005 Is the policy for updating a golden (when a *intentional* byte change ships in a follow-up) documented, so a PR can't quietly regenerate goldens to pass? [Gap, Spec §FR-006]

## Per-variant failure coverage

- [ ] CHK006 Is the requirement that every `WizardFailure` constructor has a triggering test stated as a CI-gated invariant, not just an aspiration? [Measurability, Spec §SC-003]
- [ ] CHK007 Is the same coverage requirement stated for every `BuildFailure` constructor? [Coverage, Spec §SC-003]
- [ ] CHK008 Is the mechanism by which "new constructor without triggering test" fails CI specified (e.g., compile-time enumeration property)? [Clarity, Gap]
- [ ] CHK009 Does the spec define what "triggering test" means precisely — a unit test that constructs malformed inputs vs. a manual repro vs. integration smoke — so the coverage rule is unambiguous? [Clarity]
- [ ] CHK010 Are failure variants classified into Input/Resolve/Internal families with a stable, machine-readable JSON `tag`, so the HTTP follow-up can rely on the schema without re-reading Haskell sources? [Consistency, Spec §FR-003, FR-004]

## Zero abort sites reachable

- [ ] CHK011 Is "no `abortTr` / `die` / `exitWith` reachable from `buildSwapIntent` or `buildSwapTx`" stated as a structural invariant verifiable by inspection of the call graph, not just by absence in the function body? [Measurability, Spec §SC-004]
- [ ] CHK012 Does the spec specify how transitively-called helpers (e.g., `verifyRegistry`, resolver functions) are audited for abort sites, since they may live in modules untouched by this PR? [Coverage, Gap]
- [ ] CHK013 Is the policy for genuine IO exceptions (e.g., socket open failures escaping `withLocalNodeBackend`) documented as "may propagate, not converted to typed failures"? [Clarity, Spec §Edge Cases]
- [ ] CHK014 Are CLI-shell-only abort sites (e.g., `die` in option parsing) explicitly noted as out-of-scope for the structural-invariant rule? [Clarity, Boundary]

## Tracer purely informational

- [ ] CHK015 Is the contract "passing `nullTracer` MUST yield the same `Either` value as passing any non-null tracer" stated as a requirement? [Completeness, Spec §FR-005, FR-011]
- [ ] CHK016 Is the tracer type pinned (`Tracer IO WizardEvent` / `Tracer IO BuildEvent`), and are the event constructor sets documented so a caller knows what they may observe? [Clarity, Spec §FR-005, Key Entities §Tracer]
- [ ] CHK017 Is the renderer used by the CLI to recover its `Tracer IO Text` adapter named (e.g., `renderWizardEvent`), so a refactor-time mistake that re-introduces text-typed events is detectable? [Clarity]
- [ ] CHK018 Are requirements for log-line preservation specified: "no operator-visible log line is dropped after the refactor"? [Coverage, Spec §Edge Cases]
- [ ] CHK019 Does the spec say whether the order of emitted events is part of the contract, or explicitly out of contract? [Clarity, Gap]

## Concurrency model

- [ ] CHK020 Is the requirement that `buildSwapIntent` accepts a pre-opened `Backend` parameter (rather than opening one internally) stated as a hard signature constraint? [Clarity, Spec §FR-009]
- [ ] CHK021 Is the CLI wrapper's bracketed lifetime management (`withLocalNodeBackend`) documented as the canonical pattern for single-call invocation? [Completeness, Spec §FR-009]
- [ ] CHK022 Are requirements specified for what happens if two concurrent calls share the same `Backend` and one observes a transient chain-query failure — do they share state, log streams, or anything mutable? [Coverage, Spec §FR-009]
- [ ] CHK023 Is the boundary between "process-shared" (backend, log file) and "call-scoped" (tracer, request-id) resources enumerated, so a future refactor can't accidentally promote a call-scoped resource to global? [Coverage, Gap]
- [ ] CHK024 Is the "no new process-globals" rule (no stdout writes from the builders, no fresh `MVar` shared across calls) stated as an invariant? [Completeness, Gap]

## CLI exit-code family mapping

- [ ] CHK025 Are the three numeric exit codes (64, 69, 70) pinned in requirements and mapped to specific failure families? [Clarity, Spec §FR-008]
- [ ] CHK026 Is the sysexits convention referenced (so a reader knows these are not arbitrary numbers and follow a standard)? [Clarity, Spec §FR-008]
- [ ] CHK027 Are requirements written for the fallback case "future failure variant doesn't fit one of the three families" — does it get a new family/exit code, or fall under `Internal*` → 70? [Coverage, Gap]
- [ ] CHK028 Does the spec define whether the exit code change is observable in existing CI scripts that wrap the CLI, and is there a migration note? [Dependency, Gap]
- [ ] CHK029 Is the human-readable error text preservation requirement separate from the exit-code rule, so wrappers parsing stderr aren't broken by an unrelated text-tracer refactor? [Clarity, Spec §FR-008]

## Cross-cutting invariants

- [ ] CHK030 Is the rule "this refactor changes no operator-facing artefacts (intent.json bytes, CBOR bytes, report.json bytes, stderr text, exit-code family mapping)" written as one consolidated invariant the PR review can check against? [Completeness, Spec §SC-001, SC-002, FR-008]
- [ ] CHK031 Are out-of-scope items (other wizards, HTTP endpoint, frontend page, indexer) listed prominently enough that a contributor can't drift into them mid-refactor? [Boundary, Spec §Assumptions]
- [ ] CHK032 Is the test corpus's coverage of failure paths (not just happy paths) characterised — i.e., does the existing corpus already exercise the kind of inputs that trigger `Resolve*` and `Internal*` variants, or do we need to add fixtures? [Gap]
- [ ] CHK033 Is the requirement that fourmolu, hlint, and cabal-fmt pass on every new module called out, given the project's `-Werror` and CI gating? [Completeness, Constitution §VI]
