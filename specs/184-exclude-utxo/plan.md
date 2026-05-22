# Implementation Plan: wizard input control via `--exclude-utxo` / `--extra-tx-in`

**Branch**: `184-exclude-utxo` | **Date**: 2026-05-22 | **Spec**: [spec.md](./spec.md)
**Issue**: [#184](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184)
**Sibling Issue**: [#183](https://github.com/lambdasistemi/amaru-treasury-tx/issues/183) (auto-detect reservations; complementary, not a dependency)
**Draft PR**: [#200](https://github.com/lambdasistemi/amaru-treasury-tx/pull/200)

## Status

**Current**: `spec.md` is committed at `c6339cbc` (after dropping
`reorganize-wizard` from scope as a planning-phase discovery: it is a
scaffold with no selector call). `gate.sh` is committed at `62c1e256`
and runs `git diff --check` plus `nix develop --quiet -c just ci`.
Awaiting operator approval of this plan before `/speckit.tasks`.

## Summary

Add two repeatable CLI flags — `--exclude-utxo TX_HASH#IX` and
`--extra-tx-in TX_HASH#IX` — to every wizard that performs wallet or
treasury input selection. The flags are operator-supplied input
control: exclusion filters the wallet/treasury candidate pool before
the existing selector runs; forced inclusion appends explicit outrefs
to the wizard output's `extraTxIns` array. The same outref appearing
in both flags is a structured pre-chain-query error.

The behavior is centralised in a new shared module under
`lib/Amaru/Treasury/Wizard/` so the seven wizards consume identical
parsing, validation, contradiction, filter, and error-rendering
behavior. Each wizard's CLI option record gains two list fields; each
wizard's runner applies the filter before calling its existing
selector (`selectWallet`, `selectTreasury`, `selectTreasuryForUnit`,
or `firstPureAdaRef`) and threads the forced-inclusion set into the
emitted intent. Shortfall errors are wrapped to name the excluded
refs that filtered against the empty pool.

The seven in-scope wizards are: `swap-wizard`, `disburse-wizard`,
`contingency-disburse-wizard`, `withdraw-wizard`,
`registry-init-wizard`, `stake-reward-init-wizard`, and
`governance-withdrawal-init-wizard`. `reorganize-wizard` is
out-of-scope per the spec planning refinement (scaffold-only at HEAD).

## Implementation Ownership

The orchestrator owns this plan, `tasks.md`, `gate.sh`, PR metadata,
the spec refinement above, and the post-implementation
follow-up-issue filing for the deferred asciinema bootstrap.

Every behavior-changing slice is dispatched to a driver+navigator
pair loaded with [`pair-programming`](../../../../../home/paolino/.claude/skills/pair-programming/SKILL.md).
Workers are Claude Opus medium effort per the operator's choice this
session. Each pair returns exactly one bisect-safe commit with RED+GREEN
in the same commit and the `Tasks:` trailer. Workers do not own
`specs/`, `gate.sh`, PR metadata, README, or any release/CI surface.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell
(haskell.nix toolchain at GHC 9.12.3).
**Primary Dependencies**: `optparse-applicative` for the new flag
parsers; `cardano-node-clients` for the wizard runtime; Hspec for
focused unit tests; existing wizard fixtures for byte-stable
no-flag goldens.
**Storage**: N/A. Wizard output is the existing `intent.json` shape;
the `extraTxIns` field already exists on the schema
([`IntentJSON/Schema.hs:167`](../../lib/Amaru/Treasury/IntentJSON/Schema.hs)
and parser
[`IntentJSON.hs:299`/`306`](../../lib/Amaru/Treasury/IntentJSON.hs)),
so no schema bump is required.
**Testing**: Hspec unit suites for the new shared module and per-wizard
flag wiring; existing golden suites for no-flag byte stability.
`./gate.sh` (which runs `just ci`) is the local pre-push proof.
**Target Platform**: Local Linux Nix dev shell and CI NixOS runner.
**Project Type**: Haskell CLI/library (single package).
**Performance Goals**: No measurable target. Flag handling and pool
filter are O(n) over candidate count (single-digit UTxOs per wallet).
**Constraints**: Behavior MUST be byte-identical against existing
goldens when neither flag is set; shared helper MUST live in a
sibling module to `Wizard/Common.hs` per the project's "separate
modules always" convention; no CLI surface changes outside the seven
in-scope wizards; no release/CI pipeline edits.
**Scale/Scope**: One new shared module + tests; flag wiring on seven
wizards; docs updates on three wizard pages plus `docs/index.md`.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The flags are
additive operator escape hatches. They do not change the wizard's
selection algorithm, redeemer layout, metadata shape, or the bash
recipes' positional contract. With no flag set, behavior is
byte-identical (SC-005).

**II. Pure builders, impure shell**: PASS. The shared module is pure;
the filter is a pure function `Set OutRef -> [Candidate] ->
([Candidate], Set OutRef)` (filtered pool + refs that hit). All chain
queries stay in the existing `Backend` typeclass layer.

**III. Pluggable data source, local-node default**: PASS. No new
backend or chain query is introduced. The flags operate on the
candidate set returned by the existing `Backend` query.

**IV. Build, never sign or submit**: PASS. The flags affect only the
unsigned-build intent.json; no signing or submission surface is
touched.

**V. Test-first with golden CBOR fixtures**: PASS. Every wiring slice
ships a RED proof first: a focused test that fails because the flag
is unwired or the contradiction check is absent, then GREEN in the
same reviewed slice commit. Existing goldens prove no-flag byte
stability.

**VI. Hackage-ready Haskell**: PASS. Worker slices preserve explicit
exports, Haddock on exports, fourmolu formatting, and `-Werror`-clean
builds through `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata enum or shape change.

Post-design check: PASS. The design still satisfies the constitution
after slicing — pure helper, no backend leak, additive flags, golden
byte stability, no operator-command surface added.

## Live-Boundary Diagnostic

For every behavior change in this plan, the diagnostic is
*"What system boundary does this exercise that the unit suite cannot?"*

- Shared module API (parse / filter / contradiction): pure. Unit
  tests are conclusive. No live-boundary smoke needed.
- Per-wizard wiring: the flag values flow through pure transforms
  before reaching the existing selector. Focused tests over fixture
  wallet/treasury candidate sets are conclusive. The existing
  goldens prove the no-flag path is byte-stable.
- The only live-system boundary the flags interact with is the
  chain-query result that produces the candidate pool. The flags
  apply *after* the candidate query and *before* the selector, so
  they cannot mis-shape the query itself. Existing wizard live
  smokes (e.g., devnet smokes) already exercise the query; this
  ticket does not change that path.

No new live-boundary smoke is added to `gate.sh`. The full proof is:

- `./gate.sh` for repository-local unit/golden/schema/build coverage.
- Focused per-wizard regression tests for exclusion, forced
  inclusion, contradiction, and shortfall-with-excludes.
- Existing devnet smokes for the unchanged chain-query path.
- A named operator follow-up (filed before this PR is marked ready)
  for an asciinema cast demonstrating the new flag surface on
  `swap-wizard` — see the spec's Non-Goals.

## Deliverables and Surfaces

- **New shared module** at `lib/Amaru/Treasury/Wizard/InputControl.hs`
  (sibling of [`Wizard/Common.hs`](../../lib/Amaru/Treasury/Wizard/Common.hs)).
  Exposes: `OutRef`, `parseOutRef`, `ExclusionSet`, `ForcedInclusionSet`,
  `InputControlError`, `validateInputControl`, `filterPool`,
  `excludeUtxoP`, `extraTxInP`, `renderInputControlError`,
  `renderShortfallWithExcludes`. Exact final API surface is a
  Slice 1 design output.
- **CLI flag wiring** in each in-scope wizard's option module:
  - [`Cli/SwapWizard.hs`](../../lib/Amaru/Treasury/Cli/SwapWizard.hs)
    (`WizardOpts`, `wizardOptsP`, `runWizard`)
  - [`Cli/DisburseWizard.hs`](../../lib/Amaru/Treasury/Cli/DisburseWizard.hs)
    (`DisburseWizardOpts`, `disburseWizardOptsP`,
    `ContingencyDisburseOpts`, `contingencyDisburseOptsP`)
  - [`Cli/WithdrawWizard.hs`](../../lib/Amaru/Treasury/Cli/WithdrawWizard.hs)
    (`WithdrawOpts`, `withdrawOptsP`)
  - [`Cli/RegistryInitWizard.hs`](../../lib/Amaru/Treasury/Cli/RegistryInitWizard.hs)
    (`RegistryInitWizardOpts`, `registryInitWizardOptsP`)
  - [`Cli/StakeRewardInitWizard.hs`](../../lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs)
    (`StakeRewardInitWizardOpts`, `stakeRewardInitWizardOptsP`)
  - [`Cli/GovernanceWithdrawalInitWizard.hs`](../../lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs)
    (`GovernanceWithdrawalInitWizardOpts`,
    `governanceWithdrawalInitWizardOptsP`)
- **Runner threading** in each in-scope wizard's `Tx/*Wizard.hs` so
  the filter applies before the selector and the forced-inclusion
  set lands in the wizard's emitted intent:
  - [`Tx/SwapWizard.hs`](../../lib/Amaru/Treasury/Tx/SwapWizard.hs)
    (call sites at `resolveWizardEnv:1135`, the all-ADA resolver,
    and `resolveSelections:1336`)
  - [`Tx/DisburseWizard.hs`](../../lib/Amaru/Treasury/Tx/DisburseWizard.hs)
    (`selectAndAssemble` at line ~696, with both wallet and per-unit
    treasury pools)
  - [`Tx/WithdrawWizard.hs`](../../lib/Amaru/Treasury/Tx/WithdrawWizard.hs)
    (`selectWallet 1` call at line ~440)
  - [`Tx/RegistryInitWizard.hs`](../../lib/Amaru/Treasury/Tx/RegistryInitWizard.hs)
    (`selectWallet 1` call sites at lines ~306 and ~401)
  - [`Tx/StakeRewardInitWizard.hs`](../../lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs)
    (`selectWallet 1` call at line ~303)
  - [`Tx/GovernanceWithdrawalInitWizard.hs`](../../lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs)
    (`firstPureAdaRef` call sites at lines ~684 and ~1075)
- **Wrapped shortfall errors** in each wizard's runner (or via the
  shared `renderShortfallWithExcludes`) so the existing
  `WalletNoPureAda` / `WalletShortfall` / treasury-equivalent error
  surfaces name the excluded refs that filtered against the
  shortfall pool.
- **Focused regression tests** under `test/unit/Amaru/Treasury/`:
  - shared-module tests for parse / filter / validation
  - per-wizard test(s) exercising exclusion, forced inclusion,
    contradiction, and shortfall-with-excludes
- **Documentation updates**:
  - new short shared section
    [`docs/wizard-input-control.md`](../../docs/wizard-input-control.md)
    describing both flags, the outref format, the contradiction
    error, and the in-flight-build motivation; linked from
    [`docs/index.md`](../../docs/index.md)'s command table
  - flag references added to
    [`docs/swap.md`](../../docs/swap.md),
    [`docs/disburse.md`](../../docs/disburse.md), and
    [`docs/withdraw.md`](../../docs/withdraw.md)
  - README quickstart (if it shows a wizard command) gets a one-line
    pointer to the new docs page
- **PR metadata** naming the seven in-scope wizards, the shared
  helper module name, the deferred asciinema follow-up issue link,
  and the sibling relationship to #183.

Empirical scan confirms no release/packaging surface mentions the
existing wizard commands by name in a way that requires per-wizard
release-pipeline edits (`git grep -l 'swap-wizard\|disburse-wizard\|
withdraw-wizard' .github/ flake.nix nix/`): the release pipelines
ship the `amaru-treasury-tx` executable as a single artifact,
unchanged by this ticket.

## Vertical Review Slices

Each behavior-changing slice is one bisect-safe driver+navigator
commit with RED and GREEN in the same commit and a `Tasks: T###`
trailer. The orchestrator reviews the returned diff, reruns
`./gate.sh`, amends the worker's HEAD to mark the closed task(s) in
`tasks.md`, then pushes only accepted commits.

1. **Slice 1 — Shared `InputControl` module + unit tests.** Add
   `lib/Amaru/Treasury/Wizard/InputControl.hs` with the API listed in
   *Deliverables*: outref type + `parseOutRef`, exclusion/inclusion
   set types, `validateInputControl` (contradiction check),
   `filterPool`, optparse-applicative parsers, error rendering. Add a
   new Hspec module `test/unit/Amaru/Treasury/Wizard/InputControlSpec.hs`
   with RED tests for parse roundtrip + invalid forms, contradiction
   detection, pool filter (single match, multi match, no match,
   no-op when set empty), and `renderShortfallWithExcludes` text
   contract. GREEN proof: focused unit + `./gate.sh`. Module is
   unused at this point — that is the bisect-safety guarantee.

2. **Slice 2 — `swap-wizard` end-to-end wiring.** Wire
   `--exclude-utxo` / `--extra-tx-in` into `WizardOpts` and
   `wizardOptsP`. Thread the resulting `ExclusionSet` /
   `ForcedInclusionSet` through `runWizard` so the filter applies in
   `resolveWizardEnv` (wallet pool, treasury pool) and
   `resolveSelections` (wallet pool), and so the forced-inclusion
   refs land in the emitted intent's `wallet.extraTxIns`. Wire the
   pre-chain-query contradiction check. RED proof: focused tests for
   exclusion (asserts next-largest pure-ADA picked), forced
   inclusion (asserts ref in `extraTxIns`), contradiction (asserts
   structured pre-query error), shortfall-with-excludes (asserts
   excluded refs named in error), and a golden-byte-stability assert
   for the no-flag path. GREEN proof: focused unit + golden +
   `./gate.sh`. This is the canary slice that proves the shared
   module's API survives a real wizard.

3. **Slice 3 — `disburse-wizard` + `contingency-disburse-wizard`
   wiring.** Both opts records gain the new fields (`disburseWizardOptsP`
   and `contingencyDisburseOptsP` share the parser helpers from the
   shared module). Thread through the disburse runner's
   `selectAndAssemble` so the filter applies on wallet AND per-unit
   treasury pools, and forced inclusions land in the disburse
   intent's `extraTxIns`. RED+GREEN proof: per-wizard focused tests
   in the same shape as Slice 2 + golden byte stability.

4. **Slice 4 — `withdraw-wizard` wiring.** Wire flags into
   `WithdrawOpts` / `withdrawOptsP` and thread through the runner
   (`selectWallet 1` call site). RED+GREEN proof as above.

5. **Slice 5 — `registry-init-wizard` wiring.** Two `selectWallet 1`
   call sites; both filter through the shared API. RED+GREEN proof
   as above.

6. **Slice 6 — `stake-reward-init-wizard` wiring.** Single
   `selectWallet 1` call site. RED+GREEN proof as above.

7. **Slice 7 — `governance-withdrawal-init-wizard` wiring.** Uses
   `firstPureAdaRef` (a simpler selector). Apply the shared
   `filterPool` to the candidate list before calling
   `firstPureAdaRef`; thread forced inclusions into the wizard's
   emitted intent. RED+GREEN proof as above; the test must prove
   the exclusion filters the *first* pure-ADA ref out of the pool.

8. **Slice 8 — Documentation.** New
   `docs/wizard-input-control.md`; flag references added to
   `docs/swap.md`, `docs/disburse.md`, `docs/withdraw.md`, and
   `docs/index.md`'s command table. README pointer if a wizard
   example is present. This slice is orchestrator-owned (docs are
   non-behavioral mechanical edits per the resolve-ticket
   invariants).

9. **Slice 9 — File asciinema follow-up, drop `gate.sh`, mark
   ready.** Orchestrator opens the named follow-up issue
   (scope: "adopt mkdocs asciinema-player plugin + record wizard
   input-control cast"), links it from the PR body and from
   `docs/wizard-input-control.md`, then commits `chore: drop
   gate.sh (ready for review)` and runs `gh pr ready`. This is the
   finalization slice; per `gate-script` the absence of `gate.sh`
   at HEAD is the "ready" sentinel.

## Project Structure

```text
specs/184-exclude-utxo/
|-- spec.md
|-- plan.md           # this file
`-- tasks.md          # /speckit.tasks output, not in this commit

lib/Amaru/Treasury/Wizard/
|-- Common.hs                 # existing — untouched
`-- InputControl.hs           # NEW (Slice 1)

lib/Amaru/Treasury/Cli/
|-- SwapWizard.hs                          # Slice 2
|-- DisburseWizard.hs                      # Slice 3
|-- WithdrawWizard.hs                      # Slice 4
|-- RegistryInitWizard.hs                  # Slice 5
|-- StakeRewardInitWizard.hs               # Slice 6
`-- GovernanceWithdrawalInitWizard.hs      # Slice 7

lib/Amaru/Treasury/Tx/
|-- SwapWizard.hs                          # Slice 2 (runner)
|-- DisburseWizard.hs                      # Slice 3 (runner)
|-- WithdrawWizard.hs                      # Slice 4 (runner)
|-- RegistryInitWizard.hs                  # Slice 5 (runner)
|-- StakeRewardInitWizard.hs               # Slice 6 (runner)
`-- GovernanceWithdrawalInitWizard.hs      # Slice 7 (runner)

test/unit/Amaru/Treasury/Wizard/
`-- InputControlSpec.hs                    # Slice 1

test/unit/Amaru/Treasury/Cli/
`-- {Swap,Disburse,Withdraw,RegistryInit,StakeRewardInit,GovernanceWithdrawalInit}WizardInputControlSpec.hs   # Slices 2–7

docs/
|-- wizard-input-control.md   # NEW (Slice 8)
|-- index.md                  # Slice 8 — command-table pointer
|-- swap.md                   # Slice 8 — flag reference
|-- disburse.md               # Slice 8 — flag reference
`-- withdraw.md               # Slice 8 — flag reference

amaru-treasury-tx.cabal       # touched once in Slice 1 to expose the
                              # new module + test module
```

**Structure Decision**: keep the feature inside the existing single
Haskell package. No new module family, executable, release artifact,
or release-pipeline surface is introduced.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Shared module API drift between Slice 1 and the first wiring slice forces a Slice 1 amendment. | Slice 1 ships only the API exercised by its own tests + the swap-wizard wiring tests planned for Slice 2; if Slice 2 needs a new helper, a *forward* slice extends the module. The planning-phase invariant forbids restacking accepted slices. |
| Golden CBOR fixtures shift under the no-flag path. | SC-005 is enforced in every wiring slice's RED set; any golden change fails the slice before commit. |
| `extraTxIns` ordering or de-duplication differs across wizards. | FR-006 fixes input order and de-duplication; the shared module is the single owner of this contract. |
| `firstPureAdaRef` (governance-withdrawal-init) is not symmetric with `selectWallet` so the filter call site looks slightly different. | The pure `filterPool` returns the same pre-filtered list; the wizard then calls its own selector unchanged. No selector signatures are altered. |
| Per-wizard test scaffolding multiplies maintenance cost. | Each per-wizard spec module reuses a shared test helper from `test/unit/Amaru/Treasury/Wizard/InputControlTestHelpers.hs` (introduced in Slice 1) so per-wizard specs assert behavior, not setup. |
| Operator passes a UTxO ref that doesn't exist at chain query time. | Exclusion is a no-op + log line (defensive operator UX); forced inclusion errors per FR-009. Both behaviors are tested in Slice 1's shared module and Slice 2's wizard wiring. |
| Asciinema deferral lets the deliverable rot. | Slice 9 makes the follow-up issue a hard gate before `gh pr ready`; the PR body cites the issue number. |
| A worker tries to absorb the asciinema bootstrap mid-flight. | Forbidden-scope list in every Slice 1–8 worker brief excludes `docs/assets/asciinema/`, `mkdocs.yml`, and `.github/workflows/deploy-docs.yml`. |

## Complexity Tracking

No constitution violations or added architectural complexity. The
shared `InputControl` module is additive; per-wizard wiring is
mechanical once Slice 1 exists; documentation is a flat-file
update. No new dependency, no new backend, no new release pipeline.
