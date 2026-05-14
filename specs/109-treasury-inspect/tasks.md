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

- [X] T010 [US1] Add `Inspect/Types.hs` with the minimal record `ParsedSwapOrder` (`posDestinationTreasuryHash`, `posLovelaceIn`, `posMinUsdmOut`, `posSundaeFeeLovelace`); wire into `amaru-treasury-tx.cabal` `exposed-modules` under library `amaru-treasury-tx`.
- [X] T011 [P] [US1] Add `test/unit/Amaru/Treasury/Inspect/SwapOrderDatumSpec.hs` with hspec cases: happy-path (datum from `swapOrderDatum p chunkLovelace chunkUsdm` parses back to `ParsedSwapOrder` with matching fields); wrong outer constructor; missing destination credential; missing pool params. Tests fail before implementation. Auto-discovered by `hspec-discover` once listed in the test-suite `other-modules`.
- [X] T012 [US1] Add `lib/Amaru/Treasury/Inspect/SwapOrderDatum.hs` exporting `parseSwapOrderDatum :: Data -> Maybe ParsedSwapOrder` implementing the destination-credential extraction described in [research.md R1](research.md). Pure function; total; no I/O.
- [X] T013 [US1] Run `nix develop --quiet -c just unit --match "SwapOrderDatum"`; ensure all cases pass.

**Slice A commit**: `feat(109): parse SundaeSwap order datum into ParsedSwapOrder` — landed as [`fd366bd`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fd366bd). Single commit containing T010 + T011 + T012, RED→GREEN folded. T013 ran green pre-commit.

### Slice B — Pure assembly + renderers + golden snapshot

- [X] T014 [US1] Extend `lib/Amaru/Treasury/Inspect/Types.hs` with the public report types: `InspectReport`, `ScopeSection`, `ScopeTotals`, `TreasuryUtxo`, `PendingSwapOrder`, `Outref`, `OtherAsset`, `ChainTip`, `DeploymentAnchor` (per [data-model.md](data-model.md)). ToJSON instances kept in the same module to avoid the `-Worphans` gate.
- [X] T015 [P] [US1] Add canned fixture under `test/fixtures/treasury-inspect/report.golden.json`. Inputs are Haskell-constructed (chain tip, UTxOs, parsed swap orders) so the test exercises the metadata-reading path against the existing `test/fixtures/metadata.json` and the pure pipeline against synthetic on-chain facts. Network_compliance has one leftover UTxO at `b5716ae9…#2` and two pending orders at `#3`/`#4`; a third foreign order is correctly dropped; the other four scopes render empty but uniform.
- [X] T016 [P] [US1] Add `test/golden/TreasuryInspectGoldenSpec.hs` — call `buildInspectReport`, encode via `Inspect.Render.encodeReport`, diff against `report.golden.json`. Plus a `--scope`-filter byte-length sanity test. `UPDATE_GOLDENS=1` regenerates.
- [X] T017 [US1] Add `lib/Amaru/Treasury/Inspect.hs` exporting `buildInspectReport :: TreasuryMetadata -> ChainTip -> DeploymentAnchor -> Map ScopeId [TreasuryUtxo] -> [(Outref, ParsedSwapOrder)] -> Maybe ScopeId -> InspectReport`. Pure; total.
- [X] T018 [US1] Add `lib/Amaru/Treasury/Inspect/Render.hs` with `encodeReport :: InspectReport -> ByteString` (4-space indent, alphabetical key order, trailing newline — mirrors `Report.hs:reportJsonConfig`) and `renderHuman :: InspectReport -> Text` (sketch from cli-surface.md §"Human format").
- [X] T019 [US1] [US3] `ChainTip` + `DeploymentAnchor` ship in `InspectReport`; both encoded by Slice B's renderers. Population from N2C + metadata happens in Slice D.
- [X] T020 [US1] `nix build .#checks.x86_64-linux.{unit,golden,lint,smoke}` all green: golden 15 examples (was 13, +2 from `TreasuryInspectGoldenSpec`).

**Slice B commit**: `feat(109): treasury-inspect report assembly + JSON/human render + golden` — landed as [`4e7e3ff`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4e7e3ff). T014–T019 folded. T020 ran green pre-commit.

## Phase 4 — User Story 2 (P1) — Pipe the report into automation

**Goal**: machine-readable JSON output, schema-validated by the existing project gate so the embedded shape and the docs cannot drift.

**Independent test**: `nix develop --quiet -c just schema-check` passes; the dumper exe outputs bytes equal to the in-tree `docs/assets/treasury-inspect-schema.json`.

### Slice C — JSON Schema + schema-consistency check

- [X] T021 [US2] Add `lib/Amaru/Treasury/Inspect/Schema.hs` — `treasuryInspectSchema :: Value` + `encodeTreasuryInspectSchema :: ByteString`. Mirrors `IntentJSON/Schema.hs`. Pretty-print config: 4-space indent, alphabetical keys, trailing newline.
- [X] T022 [P] [US2] Add `test/unit/Amaru/Treasury/Inspect/SchemaSpec.hs` — two assertions: (1) `docs/assets/treasury-inspect-schema.json` bytes match the Haskell source of truth; (2) the Slice B golden inspect report validates against the schema (`validateJSONSchema`).
- [X] T023 [US2] `docs/assets/treasury-inspect-schema.json` checked in; bytes equal the dumper's output.
- [X] T024 [US2] `app/amaru-treasury-inspect-schema/Main.hs` — wired as a new executable in the cabal file.
- [X] T025 [US2] Extended `justfile`: `update-schema` and `schema-check` both extended to handle the inspect schema alongside intent + tx-report.
- [X] T026 [US2] Flake checks `unit`/`golden`/`lint`/`schema`/`smoke` all green; unit count 325 (+2 from `SchemaSpec`).

**Slice C commit**: `feat(109): treasury-inspect JSON Schema + schema-check gate` — landed as [`fa14267`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fa14267). T021–T025 folded. T026 ran green pre-commit.

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

- [X] T033 `docs/inspect.md` checked in, derived from [quickstart.md](quickstart.md), trimmed of speckit-internal references, linked in `mkdocs.yml` nav between Withdraw and ChainContext.
- [X] T034 `nix develop github:paolino/dev-assets?dir=mkdocs -c mkdocs build --strict` is green.

**Slice E commit**: `docs(109): operator walkthrough for treasury-inspect` — landed as [`c2d6509`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c2d6509).

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
