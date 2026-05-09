# Phase 0 Research — `report-render`

Tracking issue: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This phase resolves the open technical questions surfaced by the
spec and the standing planner concerns recorded in
`llm/reviews/reviewer-notes.md`. There are no `NEEDS CLARIFICATION`
markers in the technical context after the decisions below.

## R1 — Helper script location and shape

- **Decision**: ship a new POSIX-shell script at
  `scripts/ops/build-swop`. Default behaviour emits Markdown
  alongside JSON; opt-out flag is `--no-markdown`.
- **Rationale**: the issue body cites this path; the repository
  already has `scripts/release/` and `scripts/smoke/` precedents,
  so `scripts/ops/` is a natural new sibling for operator-facing
  helpers. A POSIX-shell wrapper avoids adding a Haskell entry
  point for what is two `amaru-treasury-tx` invocations.
- **Alternatives considered**:
  - `nix run .#build-swop` flake app — rejected because the helper
    is meant to be a one-line wrapper invoked from operator shells,
    and `nix run` adds infra and removes the ability to pass a
    real `report.json` path through to `tx-build`.
  - A Haskell `build-swop` executable — rejected as scope creep;
    the helper carries no logic the library doesn't already.
  - Default-off Markdown — rejected; spec FR-026 mandates default-on
    with a documented opt-out.

## R2 — Leading-section bound for SC-001

- **Decision**: pin the leading section to the **first 25 lines**
  of rendered output, measured after the level-1 title line and
  the first blank line that follows it.
- **Rationale**: 25 lines comfortably covers title + action +
  scope + transaction id + explorer link + UTC validity bounds +
  conservation line + signer-roles list + swap-deal block (when
  present), while staying below the 30-line ceiling implied by
  the issue's "first 30 lines" framing. The bound is asserted
  by a per-fixture leading-section snippet golden in addition to
  the full-document byte-identity golden.
- **Alternatives considered**:
  - 30 lines (issue's literal wording) — rejected as the upper
    bound but not the assertable bound; 25 leaves slack.
  - "Up to first blank line after the action line" — rejected
    because some fixtures produce a longer leading section
    (full swap-deal block) and the bound would not be uniform.
  - Soft bound via word-count — rejected as not byte-stable.

## R3 — Treasury metadata default path

- **Decision**: default metadata path is `journal/2026/metadata.json`
  relative to the current working directory. Resolution rule:
  explicit `--metadata <path>` always wins; if absent and the
  default path exists, use it; otherwise render without metadata.
- **Rationale**: this matches the upstream
  [`pragma-org/amaru-treasury/journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)
  layout the bash recipes already assume (see constitution
  principle I — "faithful port of the bash recipes").
- **Alternatives considered**:
  - `XDG_CONFIG_HOME/amaru-treasury/metadata.json` — rejected;
    operator metadata lives next to the journal, not user config.
  - Required `--metadata` — rejected; FR-014 says metadata is
    one of several resolution sources, with a clear unresolved
    fallback when none is supplied.

## R4 — Slot → UTC derivation source

- **Decision**: derive UTC validity bounds from era summary data
  already carried by the report (`network` + system-start +
  era schedule). No chain access. Use `cardano-slotting`'s
  `EraHistory` / `interpretToWallClock` style API exposed via
  `ouroboros-consensus:cardano`.
- **Rationale**: the dependency is already in the project; the
  alternative (bundling our own slot table) duplicates upstream.
- **Alternatives considered**:
  - Hard-code per-network anchors — rejected; brittle across era
    changes and not faithful to the report's own data.
  - Render only slot numbers — rejected; FR-010 mandates UTC
    alongside slots.

## R5 — Bare-bech32 / bare-hex post-condition

- **Decision**: golden tests assert the rendered Markdown contains
  no bare bech32 (regex matching `addr1[a-z0-9]+` or `stake1...`)
  and no bare 28-byte hex (regex `[0-9a-f]{56}`) outside an
  explicit `unresolved (...)` wrapper.
- **Rationale**: this is the strongest form of FR-015/FR-016/SC-003
  — a regex post-condition is byte-stable, fixture-independent,
  and catches accidental new code paths that print raw values.
- **Alternatives considered**:
  - Type-level enforcement (a `Labelled` newtype) — preferable in
    the long run but doesn't catch render bugs by itself; we keep
    the regex assertion as the gate either way.

## R6 — Markdown library choice

- **Decision**: emit Markdown by direct `Text` builder (no
  Markdown library). Determinism and byte-identity are easier to
  guarantee with a hand-written renderer that prints exact bytes.
- **Rationale**: third-party Markdown libraries optimise for
  Markdown → HTML, not byte-stable Markdown emission. We need
  byte-stability (FR-007, SC-002).
- **Alternatives considered**:
  - `commonmark-pure` / `pandoc` — rejected; both privilege
    rendering downstream formats and reformat input on a normal
    pretty pass.

## R7 — Inline intent shape

- **Decision**: the `intent` field on `report.json` carries the
  exact same `SomeTreasuryIntent` JSON shape produced by the
  wizards (`Amaru.Treasury.IntentJSON.encodeUnifiedIntentJSON`).
  No translation, no projection.
- **Rationale**: zero translation cost; downstream tools (issue
  [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70))
  can consume the inline copy with the existing intent decoder.
- **Alternatives considered**:
  - A projected "swap-deal summary" sub-shape — rejected;
    would require a second source of truth and complicate
    backward-compatibility.

## R8 — Explorer URL pattern

- **Decision**: explorer URL keyed by network identifier:
  - `mainnet` → `https://cardanoscan.io/transaction/<txid>`
  - `preprod` → `https://preprod.cardanoscan.io/transaction/<txid>`
- **Rationale**: cardanoscan.io is the explorer the existing
  documentation references. The renderer does not validate the
  explorer page exists.
- **Alternatives considered**:
  - `cexplorer.io` — equally valid; cardanoscan picked for
    consistency with the existing `docs/` references.

All decisions above are pinned in `plan.md` (Pinned Decisions and
FR/SC Traceability).
