---

description: "Task breakdown for feat/109 treasury-inspect"
---

# Tasks: Treasury Inspect

**Input**: design documents in [`/specs/109-treasury-inspect/`](.)
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED — the project constitution §V demands golden snapshot proof per supported action, written before the production code.

## Vertical-slice mapping

Tasks are grouped by user story for traceability, but they roll up into
**five reviewable, bisect-safe commits** ("slices") which is the unit
`/speckit.implement` and the `pr` skill operate on:

| Slice | One-line goal                                            | Tasks    | Serves   |
|------:|----------------------------------------------------------|----------|----------|
| A     | SundaeSwap order datum parser, in isolation              | T010–T013 | US1     |
| B     | Pure assembly, JSON + human renderers, golden snapshot   | T014–T020 | US1, US3 |
| C     | JSON Schema, schema-dumper exe, schema-consistency test  | T021–T026 | US2     |
| D     | CLI command + N2C glue + smoke recipe                    | T027–T032 | US1, US2, US3 |
| E     | Operator-facing docs                                     | T033–T034 | (polish) |

Each slice = exactly one `git commit`. Within a slice, the RED test
task and the GREEN implementation task fold together; the tasks below
are the **planning units**, the commit is the **delivery unit**.

## Format

`- [ ] TID [P?] [Story?] Description with file path`

- `[P]` — parallelisable (different files, no dependency on incomplete tasks in this slice)
- `[USn]` — story label inside user-story phases only
- Setup, Foundational, and Polish phases have no story label

## Phase 1 — Setup

This is an existing Haskell + Nix project. No project initialisation
required.

- [ ] T001 [P] Confirm cabal file `amaru-treasury-tx.cabal` is the only build descriptor (no `hpack` package.yaml). Read once; record in WIP.md.

## Phase 2 — Foundational

No code lands in this phase — the cabal modules are added incrementally
per slice (each slice extends `exposed-modules` and `autogen-modules` as
needed). No types are introduced upfront because every type ships with
its first user in a vertical slice.

**Checkpoint**: ready to start Slice A.

## Phase 3 — User Story 1 (P1) — Confirm a freshly submitted swap landed

**Goal**: a single command shows treasury UTxOs + per-scope pending SundaeSwap orders for a selected scope (or all scopes by default), against the live N2C backend.

**Independent test (manual, operator-run)**: against the live `cardano-mainnet` socket with the production metadata.json, running `amaru-treasury-tx treasury-inspect --metadata mainnet.json --scope network_compliance` finds the `b5716ae9…` leftover UTxO at `#2` and the two pending swap-order outputs.

### Slice A — SundaeSwap order datum parser

- [ ] T010 [US1] Add `Inspect/Types.hs` with the minimal record `ParsedSwapOrder` (`posDestinationTreasuryHash`, `posLovelaceIn`, `posMinUsdmOut`, `posSundaeFeeLovelace`); wire into `amaru-treasury-tx.cabal` `exposed-modules` under library `amaru-treasury-tx`.
- [ ] T011 [P] [US1] Add `test/Spec/Treasury/Inspect/SwapOrderDatumSpec.hs` with hspec cases: happy-path (datum from `swapOrderDatum p chunkLovelace chunkUsdm` parses back to `ParsedSwapOrder` with matching fields); wrong outer constructor; missing destination credential; missing pool params. Tests fail before implementation. Wire into `test/Spec.hs`.
- [ ] T012 [US1] Add `lib/Amaru/Treasury/Inspect/SwapOrderDatum.hs` exporting `parseSwapOrderDatum :: Data -> Maybe ParsedSwapOrder` implementing the destination-credential extraction described in [research.md R1](research.md). Pure function; total; no I/O.
- [ ] T013 [US1] Run `nix develop --quiet -c just unit --match "SwapOrderDatum"`; ensure all cases pass.

**Slice A commit**: `feat(109): parse SundaeSwap order datum into ParsedSwapOrder` — single commit containing T010 + T011 + T012, RED→GREEN folded. T013 is the local-CI check before commit.

### Slice B — Pure assembly + renderers + golden snapshot

- [ ] T014 [US1] Extend `lib/Amaru/Treasury/Inspect/Types.hs` with the public report types: `InspectReport`, `ScopeSection`, `ScopeTotals`, `TreasuryUtxo`, `PendingSwapOrder`, `Outref`, `OtherAsset`, `ChainTip`, `DeploymentAnchor` (per [data-model.md](data-model.md)).
- [ ] T015 [P] [US1] Add canned fixtures under `test/fixtures/treasury-inspect/`: `metadata.json`, `utxos-treasury.json`, `utxos-swap-orders.json`, and the expected `report.golden.json`. Network: pretend mainnet; one scope (`network_compliance`) with non-empty UTxOs + 2 pending orders; the other four scopes with empty lists. ADA + USDM values picked to make rendering edge cases observable.
- [ ] T016 [P] [US1] Add `test/golden/TreasuryInspectGoldenSpec.hs` — load the fixtures, call `buildInspectReport` (Haskell only, no I/O), encode to JSON via `Inspect.Render.encodeReport`, diff against `report.golden.json`. The test must fail before T017–T018 are written. Wire into `test/Spec.hs`. Support `UPDATE_GOLDENS=1` to regenerate.
- [ ] T017 [US1] Add `lib/Amaru/Treasury/Inspect.hs` exporting `buildInspectReport :: TreasuryMetadata -> ChainTip -> Map ScopeId [TreasuryUtxo] -> [(Outref, ParsedSwapOrder)] -> Maybe ScopeId -> InspectReport`. Pure. Implements the filter rules from [data-model.md](data-model.md) §Filtering.
- [ ] T018 [US1] Add `lib/Amaru/Treasury/Inspect/Render.hs` with `ToJSON InspectReport` (and friends) producing the schema-conformant shape; plus `renderHuman :: InspectReport -> Text` producing the format sketched in [contracts/cli-surface.md](contracts/cli-surface.md) §"Human format". Provide `encodeReport :: InspectReport -> ByteString` using `aesonPrettyConfig` (mirrors `Report.hs:296+`).
- [ ] T019 [US1] [US3] Confirm the `ChainTip` + `DeploymentAnchor` fields land in `InspectReport` in this slice (covers US3's bookkeeping requirements at the type and render level — population is in slice D; the deployment anchor is parsed straight from `tmScopeOwners` with no chain query).
- [ ] T020 [US1] Run `nix develop --quiet -c just unit --match "TreasuryInspectGolden"`; ensure golden matches.

**Slice B commit**: `feat(109): treasury-inspect report assembly + JSON/human render + golden`. One commit; T014–T019 folded. T020 is the pre-commit check.

## Phase 4 — User Story 2 (P1) — Pipe the report into automation

**Goal**: machine-readable JSON output, schema-validated by the existing project gate so the embedded shape and the docs cannot drift.

**Independent test**: `nix develop --quiet -c just schema-check` passes; the dumper exe outputs bytes equal to the in-tree `docs/assets/treasury-inspect-schema.json`.

### Slice C — JSON Schema + schema-consistency check

- [ ] T021 [US2] Add `lib/Amaru/Treasury/Inspect/Schema.hs` exporting `treasuryInspectSchema :: Value` (the same JSON Schema document as [contracts/treasury-inspect-schema.json](contracts/treasury-inspect-schema.json)) and `encodeTreasuryInspectSchema :: ByteString` (pretty-encoded). Mirror `lib/Amaru/Treasury/IntentJSON/Schema.hs:75`.
- [ ] T022 [P] [US2] Add `test/Spec/Treasury/Inspect/SchemaSpec.hs` — read `docs/assets/treasury-inspect-schema.json` from disk, compare with `encodeTreasuryInspectSchema`. Test must fail before T023 + T024 are present. Wire into `test/Spec.hs`.
- [ ] T023 [US2] Add `docs/assets/treasury-inspect-schema.json` — bytes equal to the dumper's output. Initial source: copy [contracts/treasury-inspect-schema.json](contracts/treasury-inspect-schema.json).
- [ ] T024 [US2] Add `app/amaru-treasury-inspect-schema/Main.hs` — calls `BSL.putStr encodeTreasuryInspectSchema`. Wire as a new executable in `amaru-treasury-tx.cabal` (mirrors `amaru-treasury-intent-schema/`).
- [ ] T025 [US2] Extend `justfile`: add `update-schema-inspect` recipe (`cabal run … exe:amaru-treasury-inspect-schema > docs/assets/treasury-inspect-schema.json`); extend `schema-check` to also diff the inspect schema.
- [ ] T026 [US2] Run `nix develop --quiet -c just schema-check` and `nix develop --quiet -c just unit --match "Schema"`; both green.

**Slice C commit**: `feat(109): treasury-inspect JSON Schema + schema-check gate`. One commit; T021–T025 folded; T026 is the gate.

## Phase 5 — User Story 1 + 2 + 3 — CLI + IO glue

**Goal**: the new subcommand exists in the `amaru-treasury-tx` binary, dispatches to the inspect handler, fetches data via Backend, fills in the chain tip + deployment id, renders to stdout/file according to the matrix in [contracts/cli-surface.md](contracts/cli-surface.md).

**Independent test**: smoke recipe — `amaru-treasury-tx treasury-inspect --help` lists the documented flags; `amaru-treasury-tx treasury-inspect --metadata test/fixtures/treasury-inspect/metadata.json --node-socket /dev/null --network cardano-mainnet` exits 3 with the documented "node:" stderr message (no socket available, but the dispatch wiring is exercised).

### Slice D — CLI parser, IO glue, dispatch, smoke

- [ ] T027 [US1] [US2] [US3] Add `lib/Amaru/Treasury/Cli/TreasuryInspect.hs` with: an `InspectOpts` record; an optparse-applicative parser matching [contracts/cli-surface.md](contracts/cli-surface.md); `runTreasuryInspect :: Backend -> InspectOpts -> IO ExitCode`. Steps 1–6 in cli-surface.md §"Argument validation order" implemented one-for-one. The IO glue calls `queryUTxOsAtH` twice (treasury address per scope, SundaeSwap order address once), `queryChainTip` once, then `buildInspectReport`, then writes per the format/`--out` matrix.
- [ ] T028 [US1] Update `lib/Amaru/Treasury/Cli.hs`: extend `Cmd` with `CmdTreasuryInspect InspectOpts`; extend `cmdP` with the `command "treasury-inspect" …` entry.
- [ ] T029 [US1] Update `app/amaru-treasury-tx/Main.hs`: add the dispatch case `CmdTreasuryInspect opts -> exitWith =<< runTreasuryInspect backend opts`.
- [ ] T030 [P] [US2] Add a `treasury-inspect` clause to the existing `just smoke` recipe with three no-node assertions:
  1. `treasury-inspect --help` exits 0 and the output mentions `--metadata`, `--scope`, `--format`, `--out`.
  2. `treasury-inspect --metadata /nonexistent.json --node-socket /dev/null --network cardano-mainnet` exits 2 and stderr starts with `metadata:` (FR-012 bad-metadata branch).
  3. `treasury-inspect --metadata test/fixtures/treasury-inspect/metadata.json --scope no_such_scope --node-socket /dev/null --network cardano-mainnet` exits 2 and stderr names the available scopes (FR-012 wrong-scope branch). Both error cases short-circuit before any node contact, so `--node-socket /dev/null` is safe.
- [ ] T031 [US1] [US2] [US3] Run `nix develop --quiet -c just ci` end-to-end: build, unit, golden, schema-check, smoke, hlint, format-check. All green.
- [ ] T032 [US1] Sanity-cabal-check: `nix develop --quiet -c just cabal-check`; the new exe + modules pass the Hackage gate.

**Slice D commit**: `feat(109): add treasury-inspect CLI + N2C glue + smoke`. One commit; T027–T030 folded; T031 + T032 are gates.

## Phase 6 — Polish

### Slice E — Operator documentation

- [ ] T033 Copy [specs/109-treasury-inspect/quickstart.md](quickstart.md) to `docs/inspect.md`, trim the speckit-internal references, link it from the docs index (mkdocs nav, per FR-014). Keep the Acceptance-smoke section verbatim.
- [ ] T034 Run `nix develop --quiet -c just build-docs`; ensure the docs site renders without warnings.

**Slice E commit**: `docs(109): operator walkthrough for treasury-inspect`. One commit.

## Dependencies & Execution Order

### Phase dependencies

- Phase 1 (Setup) → done.
- Phase 2 (Foundational) → no-op (incremental cabal updates per slice).
- Phase 3 (US1) → no dependencies → can start now.
- Phase 4 (US2) → depends on Phase 3 (Render is the source of the JSON shape that the Schema must describe).
- Phase 5 (US1+US2+US3 CLI) → depends on Phase 3 and Phase 4 (Render needed for stdout/file output; Schema-consistency test required for the smoke recipe's `just schema-check` step).
- Phase 6 (Polish) → depends on Phase 5 (docs reference the working command).

### Slice-level dependencies

```
A ── B ── C ── D ── E
```

Each slice = exactly one commit. The chain is strictly linear (no
parallel branches) because every slice extends a contract introduced by
the previous one. There is no parallelism between slices, only inside
the planning tasks of a single slice (parallel test/impl drafting is
fine in conversation but produces one commit).

### Within each slice

- The `[P]` test task is **written first** and confirmed to fail (RED).
- The implementation task lands together with the test in one commit
  (GREEN, bisect-safe).
- The pre-commit gate task (`just unit --match …` or `just ci`) runs
  before `git commit`, not after.

## Parallel opportunities

- Inside Slice A: T010 (Types) and T011 (test) can be drafted in parallel; T012 (impl) follows the test.
- Inside Slice B: T015 (fixtures) and T016 (golden test) can be drafted in parallel; T017 + T018 (impl) follow.
- Inside Slice C: T022 (test) and T023 (schema asset) can be drafted in parallel; T021 (encoder) and T024 (exe) follow.
- No two slices are parallelisable (linear dependency chain).

## Implementation strategy

### MVP

The first reviewable + valuable state on this branch is **after Slice
B**: a pure pipeline that builds the report from sampled facts and
renders to JSON + human, with a passing golden snapshot. The CLI does
not exist yet, but a reviewer can validate the heart of the feature.

### Incremental delivery

1. Slice A lands → SundaeSwap datum parser shipped + unit-tested.
2. Slice B lands → report assembly + renderers shipped + golden-tested. (Most useful intermediate state.)
3. Slice C lands → schema and schema-check gate shipped.
4. Slice D lands → CLI exists; the feature is operator-usable.
5. Slice E lands → docs.

After Slice D, the smoke validates the feature end-to-end (sans live
node). After Slice E, the PR is ready for external review and merge.

### Live boundary smoke

Not in CI — see [plan.md](plan.md) §"Live boundary smoke" and
[research.md R8](research.md). The operator runs the acceptance scenario
from [quickstart.md](quickstart.md) §"Acceptance smoke" before merge;
result captured in the PR thread as the gate the CI cannot run.

## Notes

- Every slice commit must pass the message-gate (`references/commit-gate.sh` from the pr skill).
- After every slice push, update PR description (`gh pr edit`) so it reflects current state.
- `llm/reviews/112/` keeps per-slice handoff files locally (gitignored); each `<sha>.md` is the author handoff written for self-review per the `pr` skill.
- WIP.md is updated as slices land.
