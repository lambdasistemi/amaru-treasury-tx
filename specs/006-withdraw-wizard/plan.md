# Implementation Plan: Withdraw Wizard

**Branch**: `006-withdraw-wizard` | **Date**: 2026-05-07 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/006-withdraw-wizard/spec.md`](./spec.md)
**Tracking issue**: [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)

## Summary

Add `withdraw-wizard` and the `withdraw` branch of the unified
`tx-build` dispatcher. The wizard resolves all derivable chain and
registry values, emits a schema-v1 `TreasuryIntent 'Withdraw`, and
never builds CBOR itself. `tx-build` decodes that intent, translates it
to the existing `WithdrawIntent` shape, and runs the withdraw build
pipeline.

This plan supersedes the older issue wording that described
`withdraw-wizard | withdraw`. The release-facing build command is the
existing `tx-build`, introduced by feature 005. The feature stops at
planning in this branch until implementation is explicitly requested.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+.

**Primary Dependencies**:

- `Amaru.Treasury.IntentJSON` for the unified action-indexed intent.
- `Amaru.Treasury.Build` for the action dispatcher.
- `Amaru.Treasury.Tx.Withdraw` for the existing pure `withdrawProgram`.
- `Amaru.Treasury.Tx.SwapWizard` / `DisburseWizard` patterns for wizard
  resolver shape, trace rendering, signer conventions, and fixture
  testing.
- `Amaru.Treasury.ChainContext` / `ChainContext.Fixture` for frozen
  golden replay.
- `Amaru.Treasury.Registry.Verify` for metadata-to-chain verification.
- `cardano-node-clients` `Provider IO` for local-node queries.
- `aeson` / `aeson-pretty` for stable intent encoding.
- `optparse-applicative` for CLI parsing.

**Storage**: Filesystem only: wizard `intent.json`, builder CBOR hex,
logs, and fixture files. No database.

**Testing**: Hspec unit tests, QuickCheck properties where useful,
schema conformance tests, smoke tests, and a synthetic body-CBOR golden.
The live preprod oracle is intentionally deferred to issue #17 after
rewards accrue.

**Target Platform**: Existing CLI release targets: Linux x86_64 and
Apple Silicon Darwin. No new platform dependencies.

**Project Type**: Haskell CLI, single executable.

**Performance Goals**: Help and zero-rewards paths complete in under
10 seconds. Full live positive-rewards path is correctness-first but
must stay within the same operator expectations as swap/disburse.

**Constraints**:

- Build, never sign or submit.
- Pure transaction builders remain pure `TxBuild q e ()` programs.
- `withdraw-wizard` emits JSON only and must not call the builder.
- `tx-build` derives action and network from the intent, not CLI flags.
- Every supported action needs a golden fixture; withdraw starts with a
  synthetic fixture because real rewards are currently blocked by issue
  #17.
- Reward-account parsing must be network-aware before preprod fixtures
  can be trusted.

**Scale/Scope**:

- Extend `IntentJSON.WithdrawInputs` from an empty placeholder to a real
  payload.
- Extend `IntentJSON.Schema` and `docs/assets/intent-schema.json`.
- Add withdraw wizard and trace module.
- Add withdraw build branch in `Build`.
- Add fixtures and goldens under `test/fixtures/withdraw/` and
  `test/golden/`.
- No new package, no new executable, no new backend.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | PASS | Research records the `withdraw.sh` `+0` withdrawal amount discrepancy and requires an explicit parity decision before implementation. |
| II. Pure builders, impure shell | PASS | Existing `withdrawProgram` stays pure; resolver and dispatcher carry IO. |
| III. Pluggable data source | PASS | Reuses `Provider IO`; no direct backend leak into pure modules. |
| IV. Build, never sign or submit | PASS | Outputs unsigned CBOR only. |
| V. Test-first with golden CBOR fixtures | PASS | Synthetic withdraw golden lands before implementation; real preprod oracle remains issue #17. |
| VI. Hackage-ready Haskell | PASS | Tasks require Haddock, format, hlint, `just cabal-check`, and full CI gates. |

No violations.

## Project Structure

### Documentation (this feature)

```text
specs/006-withdraw-wizard/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── withdraw-wizard-cli.md
│   ├── tx-build-withdraw.md
│   └── withdraw-intent-json.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/
├── IntentJSON.hs                 # extend WithdrawInputs + translation
├── IntentJSON/Schema.hs          # extend withdraw schema
├── IntentJSON/Common.hs          # network-aware reward-account parse
├── Build.hs              # replace withdraw fail-closed branch
└── Tx/
    ├── Withdraw.hs               # keep pure builder; adjust only if parity demands
    ├── WithdrawWizard.hs         # new answers/env/translation/resolver
    └── WithdrawWizard/Trace.hs   # new typed trace events

app/amaru-treasury-tx/
└── Main.hs                       # add withdraw-wizard parser/runner

docs/
├── assets/intent-schema.json     # generated schema asset
├── quickstart.md                 # mention withdraw path once shipped
└── withdraw.md                   # operator page for existing intent + wizard

test/
├── fixtures/withdraw/
│   ├── synthetic/
│   └── zero-rewards/
├── golden/WithdrawGoldenSpec.hs
└── unit/Amaru/Treasury/
    ├── IntentJSONSchemaSpec.hs
    ├── IntentJSONSpec.hs
    └── Tx/WithdrawWizardSpec.hs
```

**Structure Decision**: Stay inside the existing single-package layout.
The public build command remains `tx-build`; the only new CLI surface is
`withdraw-wizard`.

## Complexity Tracking

No constitution violations or extra architectural complexity.
