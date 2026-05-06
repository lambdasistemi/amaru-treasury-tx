# Implementation Plan: Unified intent JSON + tx-build

**Branch**: `005-unified-tx-build` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/005-unified-tx-build/spec.md`](./spec.md)
**Tracking issue**: [#51](https://github.com/lambdasistemi/amaru-treasury-tx/issues/51)

## Summary

Replace the per-action `swap` and (un-shipped) `disburse` build
subcommands with a single `tx-build` subcommand that consumes a
unified `TreasuryIntent` JSON. The action selection moves from the
subcommand name into a top-level `action` field on the intent;
`network` moves from a CLI flag (currently required on both sides of
the pipe) into a top-level `network` field on the intent; the shared
structural blocks (wallet, scope, signers, validityUpperBoundSlot,
rationale) are defined once instead of once per action; the parser
helpers and the signer resolver are deduplicated into shared modules.

A `schema :: Int` version field is added so future shape changes can
be detected at parse time. The first allow-list value is `1`. Old
swap intents (no `network` field) fail at parse time — operators
re-run the wizard to obtain a v1 intent.

The CBOR bodies the build pipeline produces do **not** change as a
result of this feature. Re-recording the existing swap golden + the
in-flight ada-disburse golden against the new intent shape is the
no-behaviour-change gate (SC-004): bytes must match.

The CLI audit (research §R5) confirms `--network` /
`--network-magic` are the only redundant flags on the build side
that are dangerous to diverge. Other build flags (`--node-socket`,
`--intent`, `--out`, `--summary-out`, `--log`) are pure I/O routing
or operator-supplied connection info and stay.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`).

**Primary Dependencies**:

- existing `lib/Amaru/Treasury/**` — `Backend`, `ChainContext`,
  `Constants`, `LedgerParse`, `PParams`, `Registry/Verify`,
  `Redeemer`, `Scope`, `Summary`, `UtxoSelect`, `Validity`.
- existing
  [`Tx.SwapIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs)
  and
  [`Tx.SwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs)
  are refactored.
- existing
  [`Tx.SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs)
  is refactored to read `network` from CLI and write it into the
  unified intent.
- the **paused** feature 004's
  [`Tx.DisburseIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs),
  [`Tx.DisburseWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseWizard.hs),
  and
  [`Tx.DisburseBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseBuild.hs)
  do **not** land on this PR — they live on the 004 branch and
  rebase on top of this once it ships.
- `cardano-node-clients` `Provider IO` and `cardano-ledger-conway` —
  unchanged.
- `optparse-applicative`, `aeson`, `aeson-pretty` — unchanged.

**Storage**: filesystem only — `intent.json` (wizard output),
`<action>.cbor.hex` (build stdout), `<action>.summary.json` (build
sidecar).

**Testing**:

- New round-trip property on `TreasuryIntent` (≥100 random shapes;
  SC-002).
- Existing
  [`SwapGoldenSpec`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/golden/SwapGoldenSpec.hs)
  re-points at the new intent shape; the recorded `expected.cbor`
  bytes are unchanged (SC-004 no-behaviour-change gate).
- New unit tests around `tx-build`'s action / payload mismatch
  validation (FR-007), schema allow-list (FR-008), `--network` flag
  removal (FR-005).
- Unit test for the network-mismatch handshake path: when the N2C
  handshake reports a magic that differs from `intent.network`,
  surface `"intent declares <X>, socket is <Y>"` with both magics.
- Smoke script extended to exercise `swap-wizard | tx-build`.

**Target Platform**: Linux (CI on self-hosted NixOS runner) and
macOS (dev), x86_64 + aarch64. No new platform dependencies.

**Project Type**: CLI tool (refactor of the existing
`amaru-treasury-tx` executable; subcommand surface shrinks by one
on net).

**Performance Goals**: full pipe `<action>-wizard ... | tx-build`
against the local mainnet node MUST complete in under 10 s on the
operator workstation (matches feature 004 SC-002).

**Constraints**:

- **Faithful port** (Constitution I): the CBOR bodies the build
  pipeline produces MUST NOT change as a result of this feature.
  Operators get the same on-chain transaction shape.
- **Pure builders** (Constitution II): `swapProgram`,
  `disburseAdaProgram` (and any future `disburseUsdmProgram`)
  remain pure `TxBuild q e ()`. The dispatcher in
  `runTreasuryBuild` is the only new IO seam, and it just selects
  which builder to call.
- **Build, never sign or submit** (Constitution IV): unchanged.
- **Test-first with golden CBOR fixtures** (Constitution V,
  NON-NEGOTIABLE): the swap golden and the (in-flight) ada-disburse
  golden re-record byte-identical against the new shape. Any byte
  diff blocks merge.
- **Hackage-ready** (Constitution VI): every new export gets
  Haddock; fourmolu 70-col leading commas; explicit export lists;
  `-Werror`. `just cabal-check` must stay green.

**Scale/Scope**:

- 4 new library modules — `Amaru.Treasury.IntentJSON`,
  `Amaru.Treasury.IntentJSON.Common`,
  `Amaru.Treasury.Wizard.Common`,
  `Amaru.Treasury.TreasuryBuild`.
- 3 modules collapse / get retired — `Tx.SwapIntentJSON`,
  `Tx.SwapBuild`, `Tx.SwapWizard` (split into the unified shape).
- 1 module rewired — `app/amaru-treasury-tx/Main.hs` (subcommand
  parser, `--network` flag removal on the build side, dispatcher
  on `action`, network-mismatch error path).
- 1 cabal stanza updated — `amaru-treasury-tx.cabal`.
- 1 fixture re-recorded — `test/fixtures/swap/intent.json` (the
  CBOR `expected.cbor` does **not** change).
- 2 spec docs updated in lockstep — feature 002's spec/plan/
  contracts/quickstart, and (on the 004 branch, separately) feature
  004's spec/plan/contracts/quickstart.
- 1 published quickstart doc updated — `docs/quickstart.md`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | ✅ | The unification touches the JSON contract and the CLI surface, not the on-chain shape. CBOR bodies stay byte-identical (gated by SC-004). |
| II. Pure builders, impure shell | ✅ | All `TxBuild` programs stay pure. The new `runTreasuryBuild` is an IO dispatcher over the existing pure builders. |
| III. Pluggable data source | ✅ | Reuses the existing `Backend`/`Provider IO` typeclass. No new direct N2C dependency. |
| IV. Build, never sign or submit | ✅ | Builder still emits unsigned hex CBOR + summary; nothing about this feature touches keys or submission. |
| V. Test-first with golden CBOR fixtures | ✅ | The existing swap golden's `expected.cbor` is the no-behaviour-change reference; any byte diff blocks merge. The round-trip property on `TreasuryIntent` lands red before the parser is rewritten. |
| VI. Hackage-ready Haskell | ✅ | New shared modules follow `/haskell` skill rules; `just cabal-check` re-run as a tasks gate. |

No violations. Complexity Tracking is intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/005-unified-tx-build/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── tx-build-cli.md           # CLI flag schema for tx-build
│   └── treasury-intent-json.md   # JSON contract: shape of intent.json
├── checklists/
│   └── requirements.md  # Already created by /speckit.specify
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/
├── IntentJSON.hs                 # NEW: TreasuryIntent ADT,
│                                 # ActionPayload sum, FromJSON +
│                                 # ToJSON, encodeTreasuryIntent,
│                                 # decodeTreasuryIntent,
│                                 # translateTreasuryIntent.
├── IntentJSON/
│   └── Common.hs                 # NEW: shared parser helpers
│                                 # (parseAddr, parseTxIn,
│                                 # parseRewardAccount,
│                                 # parseGuardKeyHash,
│                                 # decodeHexBytes, mkHash28,
│                                 # mkHash32). Used by both
│                                 # IntentJSON and the wizard
│                                 # resolver.
├── TreasuryBuild.hs              # NEW: runTreasuryBuild ::
│                                 # ChainContext ->
│                                 # TreasuryBuildInputs ->
│                                 # IO TreasuryBuildResult,
│                                 # dispatching on the action
│                                 # variant.
└── Wizard/
    └── Common.hs                 # NEW: shared signer-resolver
                                  # (signerScopeFromText,
                                  # normaliseSignerToken, isHex28,
                                  # ownerForScope) + the
                                  # NetworkConstants table moves
                                  # here from Tx.SwapWizard.

lib/Amaru/Treasury/Tx/
├── Swap.hs                       # unchanged (pure builder)
├── SwapBuild.hs                  # collapsed into TreasuryBuild;
│                                 # this file is removed.
├── SwapIntentJSON.hs             # collapsed into IntentJSON;
│                                 # this file is removed.
├── SwapWizard.hs                 # refactored: imports shared
│                                 # helpers, writes the unified
│                                 # intent shape, drops local
│                                 # NetworkConstants/parsers.
├── SwapWizard/Trace.hs           # unchanged
└── Swap/Trace.hs                 # collapsed into a shared
                                  # build-side trace; this file is
                                  # removed (its constructors fold
                                  # into the new shared trace).

app/amaru-treasury-tx/
└── Main.hs                       # rewired: drops `swap`
                                  # subcommand, adds `tx-build`,
                                  # removes `--network` and
                                  # `--network-magic` from the
                                  # build side, keeps `--node-socket`
                                  # only, dispatches on the intent's
                                  # `action` field, surfaces a
                                  # typed network-mismatch error if
                                  # the N2C handshake reports a
                                  # magic that differs from
                                  # `intent.network`.

test/fixtures/swap/
├── intent.json                   # re-recorded with `schema:1`,
│                                 # `action:"swap"`, top-level
│                                 # `network:"mainnet"`. CBOR
│                                 # `expected.cbor` is UNCHANGED.
├── utxos.json                    # unchanged
├── exunits.json                  # unchanged
├── pparams.json                  # unchanged
└── expected.cbor                 # unchanged (no-behaviour-change
                                  # gate)

test/golden/
└── SwapGoldenSpec.hs             # re-points at IntentJSON;
                                  # asserts unchanged expected.cbor.

docs/                             # quickstart.md updated to use
                                  # `swap-wizard | tx-build`; old
                                  # `| swap` references removed.

specs/002-swap-wizard/            # spec.md, plan.md, quickstart.md,
                                  # contracts/swap-wizard-cli.md
                                  # updated to reflect the unified
                                  # shape (no swap subcommand;
                                  # tx-build replaces it; intent
                                  # has top-level network).
```

**Structure Decision**: Two new top-level library directories
(`IntentJSON/` and `Wizard/`) hold the shared modules. The
per-action build modules collapse into the unified
`Treasury.TreasuryBuild`. The wizard side keeps a per-action module
(`Tx.SwapWizard`, plus future `Tx.DisburseWizard`,
`Tx.WithdrawWizard`, `Tx.ReorganizeWizard`) because each wizard
asks distinct questions; only the *consumer* of the intent (the
build path) is unified.

This split preserves the operator-visible shape of feature 002's
wizard CLI (same flags, same prompts) while dramatically
simplifying the consumer side.

## Complexity Tracking

> Constitution Check passed without violations; this section is intentionally omitted.
