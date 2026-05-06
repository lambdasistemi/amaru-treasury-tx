# Implementation Plan: Disburse Wizard

**Branch**: `004-disburse-wizard` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/004-disburse-wizard/spec.md`](./spec.md)
**Tracking issue**: [#44](https://github.com/lambdasistemi/amaru-treasury-tx/issues/44)

## Summary

Add a paired `disburse-wizard` + `disburse` subcommand to
`amaru-treasury-tx`, mirroring the architecture of feature 002
([`swap-wizard`](../002-swap-wizard/plan.md)) for the disburse action.

`disburse-wizard` produces a valid `intent.json` for `disburse` from a
small typed answer record (scope, unit, amount, beneficiary address,
validity-hours, rationale, optional extra signers). The wizard
resolves the derivable fields — treasury contract address, treasury
UTxO selection, leftover lovelace + asset arithmetic, deployed-script
references, registry reference, owner key hashes, validity upper-bound
slot — via the existing
[`Provider IO`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/Provider.hs)
and the verified registry produced by
[`Amaru.Treasury.Registry.Verify`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Registry/Verify.hs).
The `disburse` subcommand consumes that JSON (from stdin or
`--intent`), runs UTxO-side selection / per-script ExUnits evaluation
/ balance, and emits unsigned Conway hex CBOR on stdout plus a
schema-conforming summary sidecar.

The translation from `(DisburseEnv, DisburseAnswers)` to
`DisburseIntentJSON` is a pure function. The IO layer is the resolver
that builds `DisburseEnv` (`Provider IO` calls + registry verify) and
the build pipeline. The wizard never invokes the build path directly —
its only output is the JSON document.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`).
**Primary Dependencies**:

- existing `lib/Amaru/Treasury/**` modules — `Backend`,
  `ChainContext`, `Constants`, `LedgerParse`, `PParams`,
  [`Tx/Disburse`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Disburse.hs)
  (pure ADA builder, kept), `Registry/Verify`, `Redeemer`, `Scope`,
  `Summary`, `UtxoSelect`, `Validity`.
- existing wizard-side modules to mirror —
  [`Tx/SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs),
  [`Tx/SwapWizard/Trace`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs).
- existing build-side modules to mirror —
  [`Tx/SwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs),
  [`Tx/SwapIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs),
  [`Tx/Swap/Trace`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Swap/Trace.hs).
- `cardano-node-clients` `Provider IO` for queries (UTxOs at address,
  registry NFT walk, current tip, slot conversion, protocol
  parameters).
- `cardano-ledger-conway` for body / witnesses / balancing,
  `cardano-ledger-api` for `estimateMinFeeTx`.
- `optparse-applicative` for CLI parsing (already used).
- `aeson` for JSON I/O (already used).

**Storage**: filesystem only — `intent.json` (wizard output),
`<action>.cbor.hex` (builder stdout), `disburse.summary.json` (builder
sidecar). No DB, no network state beyond the `Provider IO`.

**Testing**: Hspec unit tests + golden fixtures + property tests.
Specifically:

- Pure golden on `disburseToIntentJSON` for both `--unit ada` and
  `--unit usdm` (a fixture `DisburseEnv` × fixture `DisburseAnswers` →
  expected `intent.json`).
- Pure round-trip on `decodeDisburseIntent` + `translateDisburseIntent`
  against the same fixtures.
- Body-CBOR golden in `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`
  for the ADA case (rebuilt against
  [`/code/cardano-mainnet/ipc/node.socket`](mainnet socket from CLAUDE.md memory),
  ExUnits stripped before compare).
- Body-CBOR golden in
  `test/golden/Amaru/Treasury/Tx/UsdmDisburseSpec.hs` for the USDM
  case.
- Existing
  [`test/golden/SwapGoldenSpec.hs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/golden/SwapGoldenSpec.hs)
  is the structural template.

**Target Platform**: Linux (CI on self-hosted NixOS runner) and macOS
(dev), x86_64 + aarch64. No new platform dependencies.

**Project Type**: CLI tool (extension of the existing `amaru-treasury-tx`
executable; two new subcommands, no new app-target).

**Performance Goals**: full pipe `disburse-wizard ... | disburse`
against the local mainnet node MUST complete in under 10 s on the
operator workstation (success criterion SC-002). Not a hot path;
correctness >> speed.

**Constraints**:

- **Pure builders** (Constitution II): `disburseAdaProgram` /
  `disburseUsdmProgram` stay pure `TxBuild q e ()`; the new
  `runDisburseBuild` lives in IO and is the only effectful seam on the
  build side. The new `disburseToIntentJSON :: DisburseEnv ->
  DisburseAnswers -> Either DisburseError DisburseIntentJSON` is pure.
- **Faithful port** (Constitution I): the on-chain shape MUST match
  [`bin/disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh)
  +
  [`lib/build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh):
  spend wallet fuel + treasury UTxOs (script witness with
  `DisburseValue`), four reference inputs (scopes, permissions,
  treasury, registry), withdraw-zero on permissions reward account,
  beneficiary output, leftover treasury output, required signers,
  validity upper bound, aux-data.
- **Build, never sign or submit** (Constitution IV): no signing keys
  read; no submission API touched.
- **Test-first with golden CBOR fixtures** (Constitution V,
  NON-NEGOTIABLE): both `--unit ada` and `--unit usdm` ship with
  golden body-CBOR fixtures landed before the implementation that
  produces them; tests must fail red first.
- **Hackage-ready** (Constitution VI): every new export gets a Haddock
  header; fourmolu 70-col leading commas; explicit export lists;
  `-Werror`. `just cabal-check` must stay green.
- **JSON-only wizard** (mirrors FR-001 / FR-008 of feature 002): the
  wizard MUST NOT call `runDisburseBuild`. Its only output is the
  intent JSON.

**Scale/Scope**:

- 5 new library modules — `Tx/DisburseIntentJSON`, `Tx/DisburseBuild`,
  `Tx/DisburseWizard`, `Tx/Disburse/Trace`, `Tx/DisburseWizard/Trace`.
- 1 module extended — `Tx/Disburse` gains `disburseUsdmProgram`.
- 2 new subcommands wired in `app/amaru-treasury-tx/Main.hs` —
  `disburse`, `disburse-wizard`.
- ~5 new unit specs + 2 new goldens + 1 new fixture set per unit.
- No new package, sublibrary, flake output, or runtime dep.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | ✅ | Tx body shape mirrors [`disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh) + [`build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh) for both ADA and USDM cases. Wizard answers correspond 1:1 to the operator inputs of `disburse.sh`. |
| II. Pure builders, impure shell | ✅ | `disburseAdaProgram` / `disburseUsdmProgram` / `disburseToIntentJSON` are pure. IO confined to `runDisburseBuild` and the wizard resolver. |
| III. Pluggable data source | ✅ | Reuses the existing `Backend` / `Provider IO` typeclass. No new direct N2C dependency. |
| IV. Build, never sign or submit | ✅ | Builder emits unsigned hex CBOR + summary; wizard emits JSON only. |
| V. Test-first with golden CBOR fixtures | ✅ | Two new golden fixtures (ADA + USDM) land red-failing before the modules that satisfy them. |
| VI. Hackage-ready Haskell | ✅ | New modules follow `/haskell` skill rules; `just cabal-check` re-run as a tasks gate. |

No violations. The Complexity Tracking table is empty and intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/004-disburse-wizard/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── disburse-wizard-cli.md         # CLI flag schema for disburse-wizard
│   ├── disburse-cli.md                # CLI flag schema for disburse
│   └── disburse-intent-json.md        # JSON contract: shape of intent.json
├── checklists/
│   └── requirements.md  # Already created by /speckit.specify
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Tx/
├── Disburse.hs                  # extend: add disburseUsdmProgram
│                                # alongside the existing
│                                # disburseAdaProgram
├── DisburseIntentJSON.hs        # NEW: DisburseIntentJSON ADT,
│                                # decodeDisburseIntent,
│                                # translateDisburseIntent (pure)
├── DisburseBuild.hs             # NEW: runDisburseBuild :: ChainContext
│                                # -> DisburseBuildInputs ->
│                                # IO DisburseBuildResult
├── DisburseWizard.hs            # NEW: DisburseAnswers ADT,
│                                # DisburseEnv, the pure
│                                # disburseToIntentJSON, plus the
│                                # IO-bearing resolveDisburseEnv
├── Disburse/
│   └── Trace.hs                 # NEW: typed DisburseEvent for
│                                # the build path
└── DisburseWizard/
    └── Trace.hs                 # NEW: typed DisburseWizardEvent
                                 # for the wizard path

app/amaru-treasury-tx/
└── Main.hs                      # extend: wire `disburse` and
                                 # `disburse-wizard` subcommands

test/unit/Amaru/Treasury/Tx/
├── DisburseSpec.hs              # extend: round-trip on
│                                # DisburseIntentJSON, pure golden on
│                                # disburseToIntentJSON for ADA + USDM
├── DisburseBuildSpec.hs         # NEW: pure unit tests on the build
│                                # inputs/result records
└── DisburseWizardSpec.hs        # NEW: parser + translator tests

test/golden/Amaru/Treasury/Tx/
├── DisburseSpec.hs              # NEW: body CBOR vs golden (ADA case)
└── UsdmDisburseSpec.hs          # NEW: body CBOR vs golden (USDM)

test/fixtures/disburse-wizard/
├── env.ada.json                 # fixture DisburseEnv (ADA case)
├── env.usdm.json                # fixture DisburseEnv (USDM case)
├── answers.ada.json             # fixture DisburseAnswers (ADA)
├── answers.usdm.json            # fixture DisburseAnswers (USDM)
├── expected.intent.ada.json     # golden produced JSON (ADA)
└── expected.intent.usdm.json    # golden produced JSON (USDM)

test/fixtures/disburse/
├── ada/{intent,utxos,pparams}.json + body.cbor
└── usdm/{intent,utxos,pparams}.json + body.cbor
```

**Structure Decision**: Stay inside the existing layout. Five new
library modules under `lib/Amaru/Treasury/Tx/`, two new subcommand
wirings in the existing `app/amaru-treasury-tx/Main.hs`, two new unit
specs and two new goldens. No new package, no new sublibrary, no new
flake output.

The split mirrors swap-wizard (one wizard module, one build module,
one intent-JSON module, two trace modules). The justification for
keeping the wizard, the JSON contract, and the build pipeline as
separate modules is the same as in feature 002: each layer has a
distinct testable contract (pure translation; serde round-trip; IO
build), and bundling them into one module would defeat that.

## Complexity Tracking

> Constitution Check passed without violations; this section is intentionally omitted.
