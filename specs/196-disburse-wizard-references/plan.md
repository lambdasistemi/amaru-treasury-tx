# Implementation Plan: `disburse-wizard --reference` flags + `RationaleBody.references`

**Branch**: `feat/issue-196-disburse-wizard-references` | **Date**: 2026-05-22 | **Spec**: [spec.md](spec.md)

## Summary

Extend the shared `RationaleBody` / `rationaleMetadatum` builder in
`lib/Amaru/Treasury/AuxData.hs` with a new `rbReferences ::
![RationaleReference]` field, default `[]`, that serialises into the
on-chain rationale `body.references[]` array in the SundaeSwap shape.
Wire repeatable `--reference-uri / --reference-type / --reference-label`
flags into `disburse-wizard` only. Add a golden CBOR test that pins
the output against the `d6c14625…` mainnet precedent. Bump the
amaru-treasury-tx cabal version, append a CHANGELOG entry, ride the
existing release matrix. No new release surfaces; no other wizard
touched.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`)
**Primary Dependencies**: `cardano-tx-tools` (`TxBuild` DSL), `cardano-node-clients` (`Provider`), `cardano-ledger-conway` (auxiliary data), `cardano-ledger-api` (metadatum types), `optparse-applicative` (CLI), `aeson` (intent.json), `plutus-tx` (ToData)
**Storage**: filesystem only — `intent.json` (wizard output, builder input). No state added.
**Testing**: Hspec + golden CBOR fixtures + QuickCheck for properties (project standard). New golden against the `d6c14625…` rationale metadatum.
**Target Platform**: Linux (AppImage + DEB + RPM), macOS aarch64 (tar), Homebrew tap. Rides existing release matrix.
**Project Type**: library + CLI executable (this repo).
**Performance Goals**: N/A — pure CBOR serialisation, called once per build.
**Constraints**: metadatum string length ≤ 64 bytes per chunk (Cardano ledger rule). IPFS CIDv1 (~59 bytes) + `"ipfs://"` (7 bytes) requires the `[prefix, CID]` split.
**Scale/Scope**: ~4 references per disburse in the worst current case (Cyber Castellum: contract + invoice + MSA + signed email).

## Constitution Check

*Gate evaluated against `/.specify/memory/constitution.md` v0.2.0 (Ratified 2026-05-04, last amended 2026-05-15).*

| Principle | Status | Notes |
|---|---|---|
| **I. Faithful port of the bash recipes** | PASS | The bash recipe (`pragma-org/amaru-treasury/journal/2026/bin/disburse.sh`) is schema-agnostic: it accepts any `RATIONALE_JSON` blob. The d6c14625 mainnet tx was emitted via that path with a hand-crafted rationale carrying `references[]`. This slice teaches the Haskell wizard to emit the same shape via typed flags — no bash divergence. |
| **II. Pure builders, impure shell** | PASS | All changes are inside `lib/Amaru/Treasury/AuxData.hs` (pure) and CLI parsing in `app/amaru-treasury-tx/Main.hs` (pure parser, no effects). No new I/O or `Backend` typeclass changes. |
| **III. Pluggable data source, local-node default** | N/A | No backend touched. |
| **IV. Build, never sign or submit** | PASS | This slice only affects the build step; signing/submission paths unchanged. |
| **V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)** | GATE | Every behaviour-changing slice ships its golden first (RED), then implementation (GREEN), folded into one bisect-safe commit. The golden against the d6c14625 metadatum is the load-bearing fixture; existing goldens stay green unchanged. |
| **VI. Hackage-ready Haskell** | GATE | `cabal check` clean, Haddock on every export, fourmolu 70-col, leading commas/arrows, explicit export lists, StrictData, `-Werror`. The local `gate.sh` (and `just ci`) enforces this. |
| **VII. Label-1694 metadata: bash parity over spec body-shape** | PASS | The `@context` pinned commit (`ad4316d0d36cdef780f85fc2ec8b307e645ddc2a`) and the `event` enum value (`"disburse"`) are unchanged. The `references[]` field is already present in the SundaeSwap spec at that pinned commit and is present in the on-chain bash-emitted precedent — no body-shape divergence, no constitution amendment needed. |

Verdict: **PASS**. No deviations to record under Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/196-disburse-wizard-references/
├── spec.md             # /speckit.specify (committed)
├── plan.md             # this file
├── research.md         # Phase 0 — design decisions (committed alongside this file)
├── data-model.md       # Phase 1 — RationaleReference + RationaleBody shape
├── contracts/
│   ├── cli.md          # disburse-wizard --reference-* flag contract
│   └── intent-schema.md # intent.json schema delta
├── quickstart.md       # operator command for the Cyber Castellum disburse
├── checklists/
│   └── requirements.md # (committed)
└── tasks.md            # /speckit.tasks (NOT created here)
```

### Source code (touched by this slice)

```text
amaru-treasury-tx/
├── lib/Amaru/Treasury/
│   ├── AuxData.hs                       # RationaleBody.rbReferences + serialisation
│   └── IntentJSON/
│       └── Schema.hs                    # schema entry for `references`
├── app/amaru-treasury-tx/
│   └── Main.hs (or wizard parser module) # --reference-* flag wiring on disburse-wizard
├── test/
│   ├── fixtures/disburse/
│   │   └── d6c14625-references/         # NEW golden bundle (intent.json + expected CBOR)
│   └── unit/
│       └── ReferencesSpec.hs            # NEW — golden + round-trip tests
├── amaru-treasury-tx.cabal              # version bump + (if needed) new test/fixture module
├── CHANGELOG.md                         # new entry under Unreleased > Features
├── README.md (or docs/disburse.md)      # --reference-* operator section
└── docs/assets/asciinema/
    └── disburse-wizard-references.cast  # NEW per the vertical-deliverables rule
```

**Structure decision**: single-project library + CLI executable; the same layout the repo has had since #4 (`feat: add metadata in JSON format`). No new top-level directories.

## Vertical slice breakdown

Each slice produces exactly one bisect-safe commit per
resolve-ticket's invariants, dispatched to a driver+navigator worker
pair via `pair-programming`. RED + GREEN folded inside the same
commit; goldens before code per Constitution Principle V.

| # | Slice | Owned files | RED proof | GREEN proof |
|---|---|---|---|---|
| **S1** | Library: `RationaleReference` data type + `RationaleBody.rbReferences` field + `rationaleMetadatum` serialisation. Default `[]` preserves every existing golden. | `lib/Amaru/Treasury/AuxData.hs`, `test/fixtures/disburse/d6c14625-references/{intent.json,rationale.cbor}`, `test/unit/ReferencesSpec.hs`, `amaru-treasury-tx.cabal` (test module wiring only — version bump deferred to S5) | New `ReferencesSpec.hs` golden test against the d6c14625 metadatum fails (function doesn't exist / field doesn't exist) | Implement `rbReferences` + serialisation; golden passes; all prior goldens still pass; `./gate.sh` green |
| **S2** | Schema: `references` field on disburse rationale block in `intent.json`. Backward-compatible default `[]`. `update-schema` + `schema-check` recipes pass. | `lib/Amaru/Treasury/IntentJSON/Schema.hs`, schema fixtures, `test/unit/SchemaSpec.hs` if present | New schema fixture with `references[]` fails to round-trip (field rejected) | Add schema entry; round-trip passes; `just schema-check` green |
| **S3** | CLI: `disburse-wizard --reference-uri / --reference-type / --reference-label` repeatable flags. Error on stray `--reference-label` before `--reference-uri`. | `app/amaru-treasury-tx/Main.hs` (or wizard parser module per repo's layout), `test/unit/DisburseWizardSpec.hs` (or extend existing) | New parser test: invocation with two `--reference-uri` blocks produces `intent.json` with two references; invocation with stray `--reference-label` exits non-zero | Wire flags; tests pass; `./gate.sh` green |
| **S4** | Round-trip integration: build a tx via `tx-build` using the CLI-generated `intent.json` from S3; assert the resulting unsigned tx's metadatum equals the S1 golden. | `test/unit/DisburseReferencesIntegrationSpec.hs` (or extend existing integration suite) | New integration test fails (no end-to-end wiring exists yet — depends on S1 + S3) | Wire the pipeline; integration passes; `./gate.sh` green |
| **S5** | Release wiring: cabal version bump, CHANGELOG entry under `Unreleased > Features`, README docs section, asciinema cast recording + embed. | `amaru-treasury-tx.cabal`, `CHANGELOG.md`, `README.md` (or `docs/disburse.md`), `docs/assets/asciinema/disburse-wizard-references.cast`, `mkdocs.yml` (only if plugin not yet registered) | N/A — pure docs/release wiring; covered by `mkdocs --strict` + preview-URL check + `cabal check` in `./gate.sh` | Bump version, append CHANGELOG bullet, record cast, embed; `./gate.sh` green; live-preview-URL check on the docs PR build passes (per Spec Kit asciinema rule) |
| **S6** | Finalize: `chore: drop gate.sh (ready for review)`. | `gate.sh` | N/A | `git rm gate.sh`; commit; push; `gh pr ready` |

Bisect-safety per slice:
- S1 keeps all prior goldens green (default `[]` for non-disburse callers).
- S2 keeps prior intent.json fixtures parsing (the new field is optional).
- S3 keeps prior `disburse-wizard` invocations working (no flags = no references).
- S4 is integration over S1+S3 (cannot run before either); each is a no-op at HEAD before its slice lands.
- S5 is documentation / release; no behavioural change.
- S6 only removes `gate.sh`.

## Proof strategy

Per Constitution Principle V (test-first golden CBOR, NON-NEGOTIABLE):

- **The d6c14625 golden is the load-bearing fixture.** We extract the
  on-chain rationale metadatum from tx
  `d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d`
  via Blockfrost (`/txs/{hash}/metadata`), re-encode to CBOR
  byte-for-byte, and check that into
  `test/fixtures/disburse/d6c14625-references/rationale.cbor`.
- **The matching intent.json fixture** captures the inputs that
  produced that rationale: `references[]` with two entries (RCA +
  invoice) plus the same `description` / `destination.label` /
  `justification` text. The driver pair must NOT invent new copy —
  the fixture mirrors the d6c14625 on-chain rationale verbatim.
- **The S1 golden test** loads the intent, runs the in-process
  `rationaleMetadatum` builder, encodes the resulting metadatum to
  CBOR, and asserts byte equality against the fixture. RED comes
  for free: before S1's GREEN edit, `rbReferences` doesn't exist.
- **Existing fixtures are unchanged.** Every prior
  `disburse-wizard` / `swap-wizard` / `withdraw-wizard` /
  `reorganize-wizard` golden continues to encode the same bytes
  (default `[]` is field-equivalent to the previous "no field
  emitted" if both serialise to `List []` at label 1694 — verified
  in S1 by running the prior goldens unchanged).

## Live-boundary smoke

**Not required for this slice.** The change is pure CBOR
serialisation in the rationale builder, with no live-system boundary
(no new node interaction, no UTxO resolution, no balancer interaction).
The golden CBOR fixture + the existing CI gate cover the entire
contract. The integration test in S4 round-trips through the
`tx-build` path but stays in-process (no n2c socket).

The end-to-end live proof is the **Cyber Castellum mainnet disburse
itself** — tracked operationally outside this PR. That tx is the
operator follow-up the resolve-ticket protocol allows when no
in-`gate.sh` smoke makes sense.

## Deliverables coverage check

Cross-referenced against spec.md's Deliverables matrix and the
per-peer surface discovery (`git grep -l 'amaru-treasury-tx\|
disburse-wizard' .github/ flake.nix nix/ docs/ README.md
CHANGELOG.md justfile`):

| Deliverable | Slice that wires it |
|---|---|
| `RationaleBody.rbReferences` library shape change | S1 |
| `rationaleMetadatum` serialisation change | S1 |
| Schema entry for `references` | S2 |
| `--reference-*` CLI flags on `disburse-wizard` | S3 |
| Golden test against `d6c14625…` | S1 |
| Round-trip test (CLI → intent → metadatum) | S4 |
| Cabal version bump | S5 |
| `CHANGELOG.md` entry | S5 |
| README / docs section | S5 |
| Asciinema cast + embed | S5 |
| Release matrix (Linux/Darwin/Homebrew/AppImage/DEB/RPM) | Rides existing matrix; cabal bump in S5 triggers it. No new wiring. |
| `gate.sh` removal | S6 |

Every spec deliverable has at least one slice. No new release surfaces
to bootstrap.

## Complexity Tracking

> Empty — Constitution Check passed with no deviations.
