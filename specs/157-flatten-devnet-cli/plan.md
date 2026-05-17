# Implementation Plan: Flatten Devnet Supercommand & Add Init Intent Encodings

**Branch**: `157-flatten-devnet-cli` | **Date**: 2026-05-17 | **Spec**: [spec.md](./spec.md)
**Issue**: [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)

## Status

**Current**: Branch + draft PR (#162) + `gate.sh` in place. `spec.md`
and requirements checklist committed and reviewed. This plan is the
contract subagents read before slice dispatch.

**Blockers**: None. The previous DevNet recovery PRs (#147–#150)
landed the production library entries this PR exposes through the
intent / `tx-build` pipeline.

## Implementation Ownership

The orchestrator owns this specification, plan, task breakdown,
`gate.sh`, contracts, quickstart, local review, final PR metadata,
and docs alignment. Behavior-changing code slices are implemented by
one subagent at a time after this plan and `tasks.md` have passed
local review.

Each subagent receives a narrow brief naming exact task ids, owned
files / modules, forbidden scope, RED proof, GREEN proof, and the
gate to run. The orchestrator reviews the returned diff, reruns
`./gate.sh` locally, updates `tasks.md` (`[X] T### (commit: <sha>)`)
plus PR metadata, and only then starts the next subagent.

## Parent Carry-Forward Invariants (from #156)

- Shipped CLI bootstrap surface produces unsigned txs only.
- Bootstrap transaction construction lives in production library
  code, not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not
  a shipped surface.
- Library proof (`SmokeSpec`) survives every child; CLI proof
  (`smoke.sh`) lands in #161.
- Network safety: every CLI bootstrap entry fails closed for
  non-DevNet networks.

## Summary

Delete the nested `devnet <action>` parser branch, retire
`lib/Amaru/Treasury/Cli/Devnet.hs`, and extend the unified intent
JSON contract with **seven** new sub-action variants — one per
sub-transaction in the three init library entries (see
`spec.md` refinement). Plumb each new variant through the existing
`Amaru.Treasury.Build.runFromIntentEither` dispatcher so
`amaru-treasury-tx tx-build --intent <bootstrap-intent.json>` produces
the same unsigned tx CBOR hex the corresponding sub-transaction in
the library function builds today. Relocation is in-place: the four
runners stay under `lib/Amaru/Treasury/Devnet/` per #156's
library-proof invariant; they are simply no longer reachable from
any shipped CLI surface.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients`, `cardano-tx-tools`,
`cardano-ledger-conway`, `aeson` (existing intent JSON shape),
`optparse-applicative` (parser).
**Storage**: filesystem only — `bootstrap-intent.json` (input to
`tx-build`); transient run-directory artifacts produced by
`SmokeSpec` via the relocated library functions.
**Testing**: Hspec unit + golden suites; round-trip property checks
via the existing intent-JSON harness; `just schema-check` for
`docs/assets/intent-schema.json`.
**Target Platform**: Local Linux Nix development shell; the new
intent path is opt-in for operators (no live-node behavior in
default CI).
**Project Type**: Haskell CLI/library.
**Performance Goals**: No change in CLI parser construction cost or
`tx-build` build time relative to the existing `swap` / `disburse`
/ `withdraw` paths.
**Constraints**: Bisect-safe per commit; `./gate.sh` green at every
HEAD; mainnet/preprod fail-closed; relocated runners stay library
functions consumed only by `SmokeSpec` (no Hackage-public escalation).
**Scale/Scope**: Seven new sub-action intent variants, seven GADT
arms in the build dispatcher, seven golden CBOR equivalence proofs,
parser flattening + module retirement, docs alignment.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The transactions
produced by the new intent path equal what the library runners
build today; no on-chain behavior changes.

**II. Pure builders, impure shell**: PASS. Construction stays in
`lib/Amaru/Treasury/Devnet/*Init.hs`; the new intent variants are
thin tagged-union extensions of the existing JSON contract. The
relocated runners' `withDevnet` / submission paths remain confined
to the smoke harness boundary.

**III. Pluggable data source, local-node default**: PASS. `tx-build`
already uses the N2C live context; the new arms inherit the same
pluggability.

**IV. Build, never sign or submit**: PASS. The shipped CLI surface
produces unsigned tx CBOR hex via `tx-build`. The library runners
that sign/submit are no longer reachable from the parser.

**V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)**: PASS.
Every behavior-changing slice ships RED + GREEN in one reviewed
commit. Golden CBOR equivalence per init action proves the
intent-driven build equals the library-driven build, byte-for-byte.

**VI. Hackage-ready Haskell**: PASS. Explicit exports, Haddock,
fourmolu, hlint, `cabal check`, `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata body-shape change.

## Live-Boundary Diagnostic

Per the resolve-ticket diagnostic *"what system boundary does this
exercise that the unit suite cannot?"*:

- The behavior changes in this PR are **parser shape**, **JSON
  encoding**, and **GADT dispatch arms**. None of those cross a
  live-system boundary (no node fetch enters a deterministic
  computation that would be invisible at unit scope).
- The byte-identical CBOR equivalence proof is therefore the
  appropriate gate: a golden test that holds both
  "library-built CBOR" and "intent-built CBOR" fixed against each
  other for every init action proves the dispatcher selects and
  invokes the correct underlying builder with the correct inputs.
- The **live operator path** through the new intent surface is
  proved by the bash `smoke.sh` in #161. Deferring it here is
  explicit and matches the parent's two-proof-layer plan.
- The library proof at the live boundary continues to be
  `SmokeSpec` against `withDevnet`, which this PR preserves
  unchanged.

Plan-review conclusion: no extra live-boundary smoke is required in
`gate.sh` for #157. If a slice introduces a live fetch (e.g. a new
N2C call), the slice's subagent brief must add a live-boundary
check before the slice is reviewable.

## Vertical Review Slices

Each slice is one bisect-safe commit, dispatched as one subagent
run, with RED + GREEN in the same commit. Slice numbers map to task
ranges in `tasks.md`.

1. **Slice 1 — Parser retirement (RED + GREEN, one commit).**
   Delete `lib/Amaru/Treasury/Cli/Devnet.hs`; drop the `devnet`
   subparser, the four `CmdDevnet*` constructors, and their imports
   from `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`.
   RED: a parser test asserting `amaru-treasury-tx devnet …` is
   rejected. GREEN: parser test passes; `just ci` is green; the
   four runners under `lib/Amaru/Treasury/Devnet/` remain
   unmodified and reachable from `SmokeSpec`. Owned files:
   `lib/Amaru/Treasury/Cli.hs`,
   `lib/Amaru/Treasury/Cli/Devnet.hs` (delete),
   `app/amaru-treasury-tx/Main.hs`,
   `amaru-treasury-tx.cabal`,
   `test/unit/Amaru/Treasury/Cli/ParserSpec.hs` (new or extended).
2. **Slice 2 — Intent JSON scaffolding for the seven sub-actions
   (RED + GREEN, one commit).** Extend `Action`, `SAction`,
   `Payload`, `Translated` with the seven sub-action variants;
   introduce input records per sub-action and their `FromJSON` /
   `ToJSON` instances (no decoder-level network guard — the
   decoder accepts any `network: Text`, consistent with the
   existing `swap` / `disburse` / `withdraw` envelopes). Add
   `SomeTreasuryIntent` constructors and the round-trip property.
   RED: a round-trip property test for each new variant fails on
   `main`. GREEN: round-trip green; new variants appear in
   `docs/assets/intent-schema.json` (regenerate); `just
   schema-check` green. Owned files:
   `lib/Amaru/Treasury/IntentJSON.hs`,
   `lib/Amaru/Treasury/IntentJSON/Common.hs`,
   `lib/Amaru/Treasury/IntentJSON/Schema.hs`,
   `app/amaru-treasury-intent-schema/Main.hs` (if hand-rolled),
   `docs/assets/intent-schema.json`,
   `test/unit/Amaru/Treasury/IntentJSONSpec.hs`,
   `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`.
3. **Slice 3a — Build dispatch + CBOR equivalence for
   `registry-init-*` (RED + GREEN, one commit).** Extract the three
   per-sub-tx construction cores from
   `lib/Amaru/Treasury/Devnet/RegistryInit.hs` (seed-split, mint,
   reference-scripts) into pure functions reachable from
   `Amaru.Treasury.Build.runBuildExcept`. The existing
   `submitX`/`withDevnet` code in `RegistryInit.hs` stays on top of
   the extracted core unchanged. RED: three golden CBOR equivalence
   tests fail on `main`. GREEN: goldens green. Owned files:
   `lib/Amaru/Treasury/Build.hs`,
   `lib/Amaru/Treasury/Devnet/RegistryInit.hs` (extraction only),
   `test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs`,
   `test/fixtures/intent/registry-init-{seed-split,mint,reference-scripts}.json`.
4. **Slice 3b — Build dispatch + CBOR equivalence for
   `stake-reward-init-*` (RED + GREEN, one commit).** As Slice 3a
   for the two sub-txs in
   `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`.
5. **Slice 3c — Build dispatch + CBOR equivalence for
   `governance-withdrawal-init-*` (RED + GREEN, one commit).** As
   Slice 3a for the two sub-txs in
   `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`.
6. **Slice 4 — Network policy in the dispatcher (RED + GREEN, one
   commit).** Introduce a shared
   `requireDevnet :: Text -> ExceptT BuildError IO ()` helper in
   `Amaru.Treasury.Build` (or wherever the existing dispatcher
   shares helpers); call it from all seven init sub-action arms
   in `runBuildExcept` before any other work; surface a typed
   `BuildError` on rejection. RED: a unit test that builds from a
   `bootstrap-intent.json` with `network: mainnet` for every one
   of the seven sub-actions and asserts a typed error **before**
   any N2C connection is attempted. GREEN: tests pass; the
   decoder still accepts any `network: Text` (no asymmetry vs.
   existing `swap` / `disburse` / `withdraw` decoders). Owned
   files: `lib/Amaru/Treasury/Build.hs`,
   `test/unit/Amaru/Treasury/IntentJSON/NetworkGuardSpec.hs`
   (rename to `BuildNetworkGuardSpec.hs` if better situated under
   `test/unit/Amaru/Treasury/Build/`).
7. **Slice 5 — Documentation alignment (orchestrator-owned,
   single commit).** Update `README.md` and
   `docs/local-devnet-smoke.md` to describe `tx-build --intent
   <bootstrap-intent.json>` as the operator path for the seven
   sub-action intents; remove `amaru-treasury-tx devnet …`
   references; forward-reference #158–#160 (wizards, which cluster
   the seven sub-actions into three per-action questionnaires) and
   #161 (bash smoke). Refresh the PR body to match.
8. **Slice 6 — Drop `gate.sh` & ready (orchestrator-owned).**
   `chore: drop gate.sh (ready for review)`; `gh pr ready`.

## Project Structure

```text
specs/157-flatten-devnet-cli/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   |-- bootstrap-intent-json.md
|   `-- tx-build-init-cli.md
|-- checklists/
|   `-- requirements.md
`-- tasks.md

lib/Amaru/Treasury/
|-- IntentJSON.hs                  # extended with 7 sub-action variants
|-- IntentJSON/
|   |-- Common.hs
|   `-- Schema.hs                  # extended
|-- Build.hs                       # +7 dispatch arms
|-- Cli.hs                         # devnet branch removed
|-- Cli/
|   `-- Devnet.hs                  # DELETED
`-- Devnet/                        # runners RETAINED; SmokeSpec consumer
    |-- RegistryInit.hs
    |-- StakeRewardInit.hs
    |-- GovernanceWithdrawalInit.hs
    `-- DisburseSubmit.hs

app/amaru-treasury-tx/Main.hs       # devnet imports + cases removed
docs/assets/intent-schema.json      # regenerated
docs/local-devnet-smoke.md          # operator path updated
README.md                           # operator path updated
test/unit/Amaru/Treasury/Cli/ParserSpec.hs        # +devnet rejected
test/unit/Amaru/Treasury/IntentJSONSpec.hs        # +round-trip
test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs  # +schema
test/unit/Amaru/Treasury/IntentJSON/NetworkGuardSpec.hs           # NEW
test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs              # NEW (Slice 3a)
test/golden/Amaru/Treasury/StakeRewardInitIntentSpec.hs           # NEW (Slice 3b)
test/golden/Amaru/Treasury/GovernanceWithdrawalInitIntentSpec.hs  # NEW (Slice 3c)
test/fixtures/intent/registry-init-{seed-split,mint,reference-scripts}.json
test/fixtures/intent/stake-reward-init-{script-account,plain-account}.json
test/fixtures/intent/governance-withdrawal-init-{proposal,materialization}.json
```

(`scripts/smoke/devnet-local` is out of scope for #157 except for
small docs touch-ups. The bash CLI smoke against the new operator
path lives in #161.)

## Risks & Mitigations

- **Risk**: The init "construction" inside `lib/Amaru/Treasury/Devnet/
  *Init.hs` is currently entangled with `withDevnet` submission code,
  so the dispatcher cannot reuse it without refactoring.
  - **Mitigation**: Slice 3's subagent brief is allowed to extract
    a pure construction core out of the existing module (no
    behavior change), keeping the submit path on top. RED proof is
    the CBOR equivalence test; that test holds construction equal
    before and after the extraction.
- **Risk**: Hand-rolling fixture JSON drifts from real operator
  inputs over time.
  - **Mitigation**: The fixtures are derived from the same inputs
    `SmokeSpec` uses (a small test-support helper materializes
    them); the golden equivalence proof holds both sides
    constrained to those inputs.
- **Risk**: Removing `Cli/Devnet.hs` cascades into
  `app/Main.hs` imports and Cabal exposure.
  - **Mitigation**: Slice 1 owns the whole parser surface
    consistently in one commit; `just ci` is the gate.

## Complexity Tracking

No constitution violations. The principal complexity is the
construction-core extraction in Slice 3 if the existing init
modules entangle building and submitting. The plan keeps that
extraction inside the slice that introduces the equivalence proof,
so any extraction regression is caught at the byte level in the
same commit.
