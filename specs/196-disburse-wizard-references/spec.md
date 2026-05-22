# Feature Specification: `disburse-wizard --reference` flags + `RationaleBody.references`

**Feature Branch**: `feat/issue-196-disburse-wizard-references`
**Created**: 2026-05-22
**Status**: Draft
**GitHub Issue**: [#196](https://github.com/lambdasistemi/amaru-treasury-tx/issues/196)
**Related upstream issue**: [pragma-org/amaru-treasury#19](https://github.com/pragma-org/amaru-treasury/issues/19) — durable home for designated-entity addresses (not blocking).

**Input**: Extend `disburse-wizard` and the `RationaleBody` /
`rationaleMetadatum` builder in `lib/Amaru/Treasury/AuxData.hs` so that
the on-chain rationale auxiliary data for a `disburse` event can carry a
non-empty `body.references[]` array. Today the field is hard-coded to
`[]` (`AuxData.hs:98`), so vendor-paying disburses cannot anchor the
contract, invoice, or signed payment instruction IPFS pins on chain.
The shape must be **byte-for-byte compatible** with the existing
mainnet precedent — tx
[`d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d`](https://cardanoscan.io/transaction/d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d)
(May 2026, "Jacob Finkelman" 28,125 USDM disburse, two IPFS-pinned
PDFs in `body.references`).

> **Scope framing:** this slice extends one wizard (`disburse-wizard`)
> and the shared rationale builder it shares with `swap-wizard` and
> `swap-cancel`. It does **not** touch `withdraw-wizard`,
> `contingency-disburse-wizard`, or `reorganize-wizard` — their
> on-chain metadata schemas differ (withdraw uses `event: "withdraw"`
> with `milestones`; reorganize uses `event: "reorganize"` with no
> references precedent yet).
>
> The library-side shape change to `RationaleBody` is shared and will
> be visible to `swap-wizard` / `swap-cancel` as a default-`[]` field
> (no flag wiring) — those wizards keep their existing behaviour
> verbatim.

## Upstream parity reference

The on-chain rationale `body` per the SundaeSwap treasury-contracts
[metadata spec](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/offchain/src/metadata/spec.md)
includes a `references` array of `{uri, @type, label}` entries
alongside `event`, `label`, `description`, `destination`,
`justification`. The Jacob Finkelman precedent
(`d6c14625…`) carries exactly that shape:

```json
"references": [
  {
    "uri":   ["ipfs://", "bafybeiaqtexw2sfcknfcbqb463beqgfymtkiwl6qwuigjyenpx7dbls2l4"],
    "@type": "Other",
    "label": ["Remunerated Contributor Agreement", " - ", "Rust optimisations"]
  },
  {
    "uri":   ["ipfs://", "bafkreigdixsutj7d7me25xmjajeb54pxtlg5ankto7aixozpapx43ytotu"],
    "@type": "Other",
    "label": ["Invoice", " - ", "January February March Rust optimisation"]
  }
]
```

Three encoding details to preserve:

1. `uri` is a **CBOR list of strings**, split into `["ipfs://", "<CID>"]`
   when the URI begins with `ipfs://`, so each chunk fits inside the
   Cardano metadatum 64-byte string cap.
2. `@type` is a single string (`"Other"` in the precedent).
3. `label` is a **CBOR list of strings**, split on a literal `" - "`
   separator into `[lhs, " - ", rhs]` when one such separator is
   present, otherwise a 1-element list. The literal `" - "` chunk
   is preserved verbatim as the middle element.

## P1 user story

**As an Amaru network_compliance Scope Owner preparing a vendor
disburse** (Cyber Castellum milestone 1, Antithesis full contract), I
invoke `amaru-treasury-tx disburse-wizard … --reference-uri
ipfs://bafy… --reference-label "Invoice #3508 - Cyber Castellum"` (and
repeat for the agreement + signed payment-instruction CIDs), and the
emitted `intent.json` carries those references through `tx-build` into
the unsigned Conway tx body's auxiliary data at label 1694 in the
shape above. After `tx-inspect` the rationale `body.references[]`
matches the precedent shape, and after `attach-witness` + `submit` the
on-chain rationale carries the IPFS pins for audit.

**Why this priority**: the only on-chain user of this feature today is
the upcoming Cyber Castellum + Antithesis disburses on the
`network_compliance` scope. Without this slice we either ship two
$418,750-USDM-total disburses without their IPFS audit chain (losing
the entire reason for the IPFS pinning effort), or detour through the
upstream bash recipe `journal/2026/bin/disburse.sh` with a
hand-crafted `RATIONALE_JSON` (works, but bypasses our wizard's
metadata-anchor validation + intent.json schema gate).

**Independent test**: library-only golden test against the
`d6c14625…` shape (same `references[]` structure, same chunk
boundaries), plus a wizard-level test that round-trips
`disburse-wizard --reference-uri … --reference-label …` through
`intent.json` and back. No live n2c socket required.

## Acceptance scenarios

1. **Given** a `disburse-wizard` invocation with **zero**
   `--reference-uri` flags, **when** the wizard writes `intent.json`,
   **then** the rationale block contains `references: []` (current
   behaviour preserved verbatim — golden test pins this against an
   existing fixture).
2. **Given** a `disburse-wizard` invocation with **one**
   `--reference-uri ipfs://bafy…` `--reference-label "Invoice #3508"`
   (no `--reference-type`), **when** the wizard writes `intent.json`,
   **then** the rationale carries one reference with `@type: "Other"`
   (default), `uri: ["ipfs://", "bafy…"]`, and `label: ["Invoice #3508"]`.
3. **Given** a `disburse-wizard` invocation with **two**
   `--reference-uri` flags interleaved with their `--reference-label`
   / `--reference-type` flags in the order shown below, **when** the
   wizard runs and `tx-build` emits the rationale metadatum, **then**
   the resulting `body.references[]` is byte-identical to the
   `d6c14625…` shape for the same inputs (this is the golden test;
   verifies chunking, list ordering, and metadatum string cap).
   ```
   --reference-uri ipfs://bafybeiaqtexw2sfcknfcbqb463beqgfymtkiwl6qwuigjyenpx7dbls2l4 \
   --reference-type Other \
   --reference-label "Remunerated Contributor Agreement - Rust optimisations" \
   --reference-uri ipfs://bafkreigdixsutj7d7me25xmjajeb54pxtlg5ankto7aixozpapx43ytotu \
   --reference-type Other \
   --reference-label "Invoice - January February March Rust optimisation"
   ```
4. **Given** a `disburse-wizard` invocation where a `--reference-label`
   appears **before any `--reference-uri`** on the same line, **when**
   the wizard parses the CLI, **then** it exits non-zero with a clear
   error naming the malformed flag (the `--reference-uri` flag opens a
   new reference slot; subsequent `--reference-type` / `--reference-label`
   populate it).
5. **Given** an upstream `swap-wizard` or `swap-cancel` invocation
   (unchanged operator command), **when** the wizard writes
   `intent.json`, **then** the rationale block continues to carry
   `references: []` — the library-side `RationaleBody.references`
   field defaults to `[]` and only `disburse-wizard` exposes flags
   to populate it.

## Edge cases

- **URI not starting with `ipfs://`**: emit a 1-element `uri` list with
  the URI verbatim. No chunking. (Future HTTPS or arweave anchors keep
  working.)
- **Label without a `" - "` separator**: emit a 1-element `label` list
  with the label verbatim. (Operators don't have to use the separator
  pattern; it's only there to preserve precedent byte parity.)
- **Label with multiple `" - "` separators**: split only on the first
  occurrence (`" - " | rest`). Avoids surprise rebalancing if a vendor
  name contains `" - "`.
- **`--reference-type` repeated for the same slot before
  `--reference-label`**: last `--reference-type` wins. Operators
  typically pass `--reference-type` zero times (default `"Other"`).
- **A chunk that exceeds the metadatum 64-byte string cap**: fail at
  intent-validation time with a clear error. The CID-aware split is
  sufficient for the IPFS case (the longest known CIDv1 is 59 bytes,
  + `"ipfs://"` 7 bytes = 66 — too long for one string, fine when
  split as `["ipfs://", "<CID>"]`). For non-IPFS URIs longer than 64
  bytes we emit the error; the caller can re-encode.
- **`intent.json` from before this change** (no `references` field):
  parse as `references: []`. Backward-compatible.

## Requirements

### Functional requirements

- **FR-001**: `RationaleBody` (`lib/Amaru/Treasury/AuxData.hs`) MUST
  gain a `rbReferences :: ![RationaleReference]` field, where
  `RationaleReference` has `rrUri :: !Text`, `rrType :: !Text`,
  `rrLabel :: !Text`. The existing `swapRationaleMetadatum` /
  `disburseRationaleMetadatum` helpers MUST keep their existing
  arity (default `rbReferences` to `[]` internally).
- **FR-002**: `rationaleMetadatum` MUST serialise `rbReferences` into
  the SundaeSwap `body.references[]` array, with `uri` and `label`
  chunked exactly as the d6c14625 precedent (see "Upstream parity
  reference" above). When the list is empty, emit `List []` (current
  behaviour — golden tests already pin this).
- **FR-003**: `disburse-wizard` MUST accept repeatable CLI flags
  `--reference-uri TEXT`, `--reference-type TEXT` (default `"Other"`),
  `--reference-label TEXT`. Each `--reference-uri` opens a new
  reference slot; subsequent `--reference-type` / `--reference-label`
  populate the most-recently-opened slot. A `--reference-type` or
  `--reference-label` that appears before any `--reference-uri` MUST
  fail with a clear error.
- **FR-004**: The unified `intent.json` schema (`lib/Amaru/Treasury/
  IntentJSON/Schema.hs`) MUST gain a `references` field on the
  disburse rationale block. The field MUST be optional (default `[]`)
  so existing intents continue to validate. Schema validation runs
  via the existing `update-schema` / `schema-check` recipes; both must
  pass.
- **FR-005**: A fresh release of `amaru-treasury-tx` (cabal version
  bump per the project's release policy) MUST be cut before this
  branch merges, so the Cyber Castellum disburse on mainnet can build
  against the released binary rather than a local checkout. Release
  pipeline wiring (Linux AppImage, DEB, RPM, Darwin tar, Homebrew tap)
  rides the existing matrix — no new surfaces.
- **FR-006**: `withdraw-wizard`, `contingency-disburse-wizard`,
  `reorganize-wizard`, `swap-wizard`, `swap-cancel` MUST NOT gain
  `--reference-*` flags. Their library shape SHOULD keep working
  unchanged (i.e. the shared `RationaleBody` change defaults
  `rbReferences = []` for them).

### Key entities

- **RationaleReference**: a single external-document pointer. Three
  fields: `rrUri` (string, ≥1 byte; `ipfs://<CID>` is the canonical
  shape; HTTPS / arweave also supported), `rrType` (string, default
  `"Other"`; SundaeSwap spec leaves the enumeration open), `rrLabel`
  (string, ≥1 byte; literal `" - "` is the optional split marker
  preserving precedent byte parity).
- **RationaleBody**: gains `rbReferences :: ![RationaleReference]`.
  Default `[]` for non-disburse callers. No other field changes.

## Success criteria

- **SC-001**: A golden test against the `d6c14625…` rationale
  metadatum passes byte-for-byte (CBOR equality of the label-1694
  metadatum).
- **SC-002**: All existing golden tests (every prior `swap-wizard` /
  `disburse-wizard` / `withdraw-wizard` / `reorganize-wizard` fixture
  in `test/fixtures`) continue to pass unchanged.
- **SC-003**: The mainnet Cyber Castellum milestone 1 disburse
  (18,750 USDM, `network_compliance` scope) ships with all four
  IPFS-pinned references in its on-chain rationale: Whitehacking
  contract, Invoice #3508, CAG MSA, Laura Dugan signed-email
  confirmation. Verified via `tx-inspect` after build, and again on
  mainnet after submission.
- **SC-004**: The wizard exits non-zero with a clear, named error on
  any malformed `--reference-*` flag combination (Acceptance Scenario
  4 + the FR-003 negative case).
- **SC-005**: `nix flake check` and `just ci` pass green on the PR
  branch. The PR ships a `chore: drop gate.sh` final commit and CI
  green before merge.

## Deliverables

| Artifact | Surface | This ticket ships to it? |
|---|---|---|
| `RationaleBody.rbReferences` library shape change | `lib/Amaru/Treasury/AuxData.hs` | yes |
| `rationaleMetadatum` serialisation change | same module | yes |
| Schema entry for `references` | `lib/Amaru/Treasury/IntentJSON/Schema.hs` + `update-schema` / `schema-check` recipes | yes |
| `--reference-*` CLI flags | `app/amaru-treasury-tx/Main.hs` (or wherever the disburse-wizard parser lives) | yes |
| Golden test against the `d6c14625…` shape | `test/fixtures/<new>` + `test/unit/...` | yes |
| Round-trip test (CLI → intent.json → rationale metadatum) | `test/unit/...` | yes |
| Cabal version bump | `amaru-treasury-tx.cabal` | yes |
| `CHANGELOG.md` entry | `CHANGELOG.md` | yes |
| Release matrix (Linux AppImage / DEB / RPM / Darwin tar / Homebrew tap) | `.github/workflows/release.yml`, `.github/workflows/darwin-release.yml`, `.github/workflows/darwin-dev-homebrew.yml` (already wired; cabal bump triggers them) | no change needed (rides existing matrix) |
| README docs section for `--reference-*` flags | `README.md` and/or `docs/...` | yes |
| **asciinema cast for `disburse-wizard --reference-*` usage** | `docs/assets/asciinema/disburse-wizard-references.cast` + embed in the prose docs page | yes — per the vertical-deliverables rule for executable surface changes |

Discovery command for peer surfaces (recorded for plan review):

```bash
git grep -l 'amaru-treasury-tx\|disburse-wizard' .github/ flake.nix nix/ docs/ README.md CHANGELOG.md justfile
```

## Assumptions

- The d6c14625 mainnet precedent is the authoritative on-chain shape
  we copy. If SundaeSwap revises the metadata spec before this ships,
  we follow up in a separate ticket.
- The cardano metadatum 64-byte string cap is the binding constraint
  on chunk size. Hex-encoded CIDv1 (e.g. `bafybei…` 59 bytes) plus
  `"ipfs://"` (7 bytes) split cleanly. No general-purpose chunker
  needed for the IPFS case.
- The release pipeline (`amaru-treasury-tx.cabal` version bump →
  Linux/Darwin/Homebrew matrix) is already wired and battle-tested.
  This ticket does not modify release infrastructure; it only bumps
  the cabal version.
- Operators construct `--reference-label` strings client-side; the
  wizard does no semantic validation beyond the encoding-level checks
  (`" - "` split, ≤64-byte chunk cap).
- `withdraw-wizard` / `contingency-disburse-wizard` / `reorganize-wizard`
  / `swap-wizard` / `swap-cancel` have no operator demand for
  references[] yet. If they do later, this slice's `RationaleBody.references`
  field is already shared — the only added cost is the per-wizard CLI
  flag wiring + their own golden test.

## Out of scope

- Upstream `journal/2026/metadata.json` schema additions for designated
  vendor/off-ramp entities — tracked in
  [pragma-org/amaru-treasury#19](https://github.com/pragma-org/amaru-treasury/issues/19).
- `destination.details.anchorUrl` / `destination.details.anchorDataHash`
  from the SundaeSwap metadata spec — separate ticket if/when a vendor
  needs the destination-side anchor (CAG off-ramp wallet uses `label`
  only in the d6c14625 shape and does not need `details`).
- Changes to `withdraw-wizard`, `contingency-disburse-wizard`,
  `reorganize-wizard`, `swap-wizard`, `swap-cancel` flag surfaces.
- A general-purpose URL chunker for metadatum strings longer than 64
  bytes after the IPFS-aware split.
- The Cyber Castellum and Antithesis disburses themselves — tracked
  operationally outside this PR, contingent on this PR's release.
