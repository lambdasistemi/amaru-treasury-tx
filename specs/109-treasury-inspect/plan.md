# Implementation Plan: Treasury Inspect

**Branch**: `feat/109-treasury-inspect` | **Date**: 2026-05-14
**Spec**: [spec.md](spec.md) | **Issue**: [#109](https://github.com/lambdasistemi/amaru-treasury-tx/issues/109) | **PR**: [#112](https://github.com/lambdasistemi/amaru-treasury-tx/pull/112)

## Summary

A new read-only top-level subcommand `treasury-inspect` that reads the same
metadata.json the wizards already consume, queries the live cardano-node, and
reports two things per scope: the treasury script-address balance (with ADA
and USDM totals + per-UTxO breakdown) and the list of pending SundaeSwap
order UTxOs whose inline datum names that scope's treasury as the
swap-payout destination. Plus a bookkeeping section pinning the current
chain tip + the deployment anchor (scope-owners-NFT outref from metadata).

Approach: keep the inspect logic pure (a function from sampled facts —
metadata + chain tip + UTxOs at two addresses — to a `Report` value) and put
all I/O behind the existing `Backend`. The rendering (human + JSON) and the
JSON Schema both live next to the report types, mirroring the existing
`Amaru.Treasury.IntentJSON.Schema` precedent.

## Technical Context

- **Language**: Haskell, GHC 9.6 (project pin via haskell.nix; same as the
  rest of `amaru-treasury-tx`).
- **Primary dependencies**: `optparse-applicative` (existing CLI), the
  `Provider` interface from `cardano-node-clients` (existing), `aeson`,
  `aeson-pretty`, `text`, `plutus-tx` (for parsing the SundaeSwap order
  datum's destination-credential field), `bytestring`.
- **Storage**: stateless — single-shot LSQ query per invocation; no
  persistent state, no cache.
- **Testing**: `hspec` for unit + golden tests, snapshot golden JSON file
  per scenario.
- **Target platform**: Linux + macOS, x86_64 + aarch64 — same as the
  existing release matrix.
- **Project type**: CLI tool, single binary `amaru-treasury-tx` (plus the
  schema-dumper exe pattern already established).
- **Performance goals**: bounded by N2C round-trip; for 5 scopes × ~10
  UTxOs per address the report takes one chain-tip query + one UTxO-set
  query per address (treasury + swap-order). Target: <2s wall time on a
  warmed-up local node.
- **Constraints**: no new metadata fields; no signing; no submission; no
  block-walking or tx-history queries (that would require an indexer, which
  is constitution §III follow-on territory).
- **Scale/scope**: 5 scopes today, 5+ in the future. UTxO set per address
  is small (single-digit to low-tens). Report is fully in-memory.

## Constitution Check

| Principle                                            | Pass | Notes |
|------------------------------------------------------|:---:|---|
| I. Faithful port of the bash recipes                 | ✓   | `treasury-inspect` has no bash counterpart. The spec's Out of Scope + Assumptions sections justify the new-command status: it replaces a manual two-`cardano-cli` workflow that *operators* run, not a journal recipe. This is an extension, not a divergence. |
| II. Pure builders, impure shell                      | ✓   | Inspect produces a `Report`, not a `TxBuild`, so the literal "pure builder" type does not apply. The spirit applies: `Amaru.Treasury.Inspect` is a pure function `(Metadata, ChainTip, [TreasuryUtxo], [SwapOrderUtxo]) -> InspectReport`; the N2C calls live in the CLI layer behind `Backend`. |
| III. Pluggable data source, local-node default       | ✓   | Default backend stays N2C. The two queries needed (`queryUTxOsAtH` for treasury + swap-order addresses, `queryChainTip`) are already in the `Provider` interface; `Backend` re-exports them if needed (additive). |
| IV. Build, never sign or submit                      | ✓   | Read-only by design. No signing, no submission, no key material consulted. |
| V. Test-first with golden CBOR fixtures (NON-NEG)    | ✓ (adapted) | Inspect produces **JSON**, not CBOR. The constitutional spirit — "every supported action ships with at least one golden test, written before the implementation" — is preserved by `test/golden/TreasuryInspectGoldenSpec.hs` comparing the JSON report against a checked-in golden file. Documented as a deliberate adaptation, not a deferral. |
| VI. Hackage-ready Haskell                            | ✓   | All new modules get Haddock on every export, fourmolu-formatted, `-Werror` clean, listed in `exposed-modules` + `autogen-modules` as needed. `just cabal-check` extended-recipe coverage. |

No violations — Complexity Tracking section is intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/109-treasury-inspect/
├── spec.md
├── plan.md                           # this file
├── research.md                       # design decisions resolved during planning
├── data-model.md                     # entities → Haskell types
├── quickstart.md                     # operator walkthrough (also seeds docs/inspect.md)
├── contracts/
│   ├── cli-surface.md                # exact optparse-applicative shape
│   ├── treasury-inspect-schema.json  # output JSON shape (draft seed for docs/assets)
│   └── example-report.json           # canned full-report example
├── checklists/
│   └── requirements.md
└── tasks.md                          # produced by /speckit.tasks (next phase)
```

### Source code (repository root)

```text
app/
├── amaru-treasury-tx/Main.hs                   # dispatch new CmdTreasuryInspect
└── amaru-treasury-inspect-schema/Main.hs       # dumps JSON Schema to stdout
                                                # mirrors app/amaru-treasury-intent-schema/Main.hs

lib/Amaru/Treasury/
├── Inspect.hs                                  # pure: assemble Report from sampled facts
├── Inspect/
│   ├── Types.hs                                # InspectReport, ScopeSection, TreasuryUtxo, PendingOrder
│   ├── Render.hs                               # ToJSON + human renderer
│   ├── Schema.hs                               # treasuryInspectSchema :: Value; encoder
│   └── SwapOrderDatum.hs                       # destination-credential extraction from inline datum
├── Cli/
│   └── TreasuryInspect.hs                      # optparse-applicative parser + IO glue
├── Cli.hs                                      # add CmdTreasuryInspect variant
└── Backend.hs                                  # additive: re-export missing queries if any

test/
├── golden/
│   └── TreasuryInspectGoldenSpec.hs            # JSON snapshot test (golden file)
├── fixtures/
│   └── treasury-inspect/
│       ├── metadata.json                       # canned input (small but realistic)
│       ├── utxos-treasury.json                 # canned chain-side facts
│       ├── utxos-swap-orders.json
│       └── report.golden.json                  # the golden output
└── Spec/Treasury/Inspect/
    └── SchemaSpec.hs                           # asserts embedded schema == docs/assets file

docs/
├── inspect.md                                  # operator walkthrough (linked from index)
└── assets/treasury-inspect-schema.json         # checked-in JSON Schema

justfile                                        # extend schema-check; add update-schema-inspect
amaru-treasury-tx.cabal                         # new modules + new exe + test wiring
```

**Structure Decision**: the layout mirrors the existing `Amaru.Treasury.IntentJSON`
+ `Amaru.Treasury.Report` patterns so reviewers can validate each new file by
analogy. The schema-dumper executable in `app/amaru-treasury-inspect-schema/`
matches the existing `app/amaru-treasury-intent-schema/` precedent and lets the
justfile reuse the same regenerate-and-diff recipe shape that today validates
`docs/assets/intent-schema.json`.

## Phase 0 — Research (artifact: [research.md](research.md))

Resolves: the SundaeSwap order address source, the destination-credential
extraction from the inline datum (the actual scope-attribution field, not
the four-owner authorised-signers list), the USDM asset identification,
the `--out` and `--format` semantics in edge cases, and the rationale for
the Backend additive change (or lack thereof). Each decision is recorded
with rationale + considered alternatives.

## Phase 1 — Design & Contracts

Artifacts:

- [data-model.md](data-model.md) — entities from the spec → concrete Haskell
  record types and the canonical CBOR / JSON shapes.
- [contracts/cli-surface.md](contracts/cli-surface.md) — exact
  optparse-applicative shape: flags, defaults, exit-code taxonomy.
- [contracts/treasury-inspect-schema.json](contracts/treasury-inspect-schema.json)
  — the seed JSON Schema (will land at `docs/assets/treasury-inspect-schema.json`).
- [contracts/example-report.json](contracts/example-report.json) — a worked
  example matching the schema.
- [quickstart.md](quickstart.md) — operator walkthrough; will be reduced and
  copied to `docs/inspect.md` during implement.

No agent-context script is run — the existing CLAUDE.md already covers Haskell
and the project conventions; this feature adds no new technology.

## Status

- ✅ Spec accepted (amended during planning per research.md R1)
- ✅ Plan + research + data-model + contracts + quickstart approved
  by self-review against the `pr` skill plan-review gate
- ✅ Tasks approved (`tasks.md`, five vertical slices A–E)
- ✅ `/speckit.analyze` consistency findings C1–C5 resolved
- ✅ **Slice A landed** — SundaeSwap order datum parser
  ([commit `d725316`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/d725316)).
  5/5 unit tests passing.
- ✅ **Slice B landed** — pure assembly + JSON/human render + golden
  ([commit `4989e74`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4989e74)).
  Golden test 2/2 passing.
- ✅ **Slice C landed** — JSON Schema + schema-dumper exe + extended
  `just schema-check`. Schema-consistency tests 2/2 passing.
- ✅ **Slice D landed** — CLI parser + N2C glue + smoke
  ([commit `fa68ba2`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fa68ba2)).
  `amaru-treasury-tx treasury-inspect …` exists on the binary;
  no-node smoke covers `--help` + two FR-012 exit-2 branches;
  flake checks all green.
- ✅ **Slice E landed** — `docs/inspect.md` operator walkthrough
  ([commit `c2d6509`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c2d6509)).
  Linked from mkdocs nav; `mkdocs build --strict` green.
- ✅ **Live-boundary smoke run**: `treasury-inspect` against the
  live mainnet node returned the actual treasury state per scope
  (chain tip slot 187,191,998; 5 pending swap orders in
  `network_compliance`; ~9M ADA + ~116k USDM across all five
  scopes). SC-003 satisfied; full output to be attached to the
  PR thread.

(Branch rebased onto `cd6a761` after #106 merged; earlier slice
SHAs above reflect the post-rebase chain.)
