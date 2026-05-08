# Implementation Plan: Aggregate Wallet UTxOs as Fuel in swap-wizard

**Branch**: `007-aggregate-wallet-utxos` | **Date**: 2026-05-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-aggregate-wallet-utxos/spec.md`

## Summary

Replace the wizard's single-largest-pure-ADA-UTxO `selectWallet` with a largest-first aggregator that picks UTxOs until the cumulative ADA covers the wallet's per-chunk SundaeSwap deposit obligation plus a 2 ADA fee slack. Thread the resulting list through the resolver env, the unified `TreasuryIntent` JSON via a new optional `wallet.extraTxIns` field, and `swapProgram` so every selected UTxO becomes a tx input (head also serves as collateral). Replace the silent fall-through to `BalanceFailed (InsufficientFee ...)` with a typed `ResolverWalletShortfall` error emitted by the resolver before any intent is written. Backwards-compatible: pre-feature intent.json files (no `extraTxIns`) decode into `siExtraWalletInputs = []` and produce byte-identical txs.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`).
**Primary Dependencies**: `cardano-node-clients` (`TxBuild q e a` DSL, `selectWallet` location), `cardano-ledger-conway` (Conway tx body for `inputsTxBodyL`/`collateralInputsTxBodyL`), `aeson` (intent.json shape).
**Storage**: filesystem only — `intent.json` (wizard output, builder input). No DB or persistent state added by this feature.
**Testing**: Hspec unit tests (selection algorithm cases, swap-program input-set assertion), QuickCheck round-trip property in `IntentJSONSpec`, golden CBOR/JSON fixtures, JSON-Schema validation in `IntentJSONSchemaSpec`.
**Target Platform**: CLI binary on Linux + macOS (release artifacts; mainnet + preprod). The wizard talks to `cardano-node` via N2C.
**Project Type**: Single Haskell library + CLI executable (one cabal package).
**Performance Goals**: N/A — selection runs over ≤ a few dozen wallet UTxOs in O(n log n) sort + O(n) accumulate. Performance not a feature axis here.
**Constraints**: Conway era, mainnet+preprod constants only; SundaeSwap V3 order datum shape is upstream — we don't change it.
**Scale/Scope**: Single feature inside `swap-wizard`. Touches `Tx/SwapWizard.hs`, `Tx/Swap.hs`, `IntentJSON.hs`, `IntentJSON/Schema.hs`, `TreasuryBuild.hs`, the `app/amaru-treasury-tx/Main.hs` CLI, and `app/swap-probe/Main.hs`. Out of scope: `Tx/DisburseWizard.hs`, `Tx/WithdrawWizard.hs`, the `Tx/DisburseIntentJSON.hs` legacy schema, and the #64 root-cause fix (treasury self-funds extras).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The constitution at `.specify/memory/constitution.md` v0.1.0 enumerates six principles. Walking each:

- **I. Faithful port of the bash recipes.** The upstream bash `swap.sh` + `select_treasury_utxos.sh` does single-UTxO wallet fuel selection (via `resolve_fuel`). This feature *diverges intentionally* by aggregating multiple UTxOs. Justification (recorded here per the principle's "written justification" clause): the upstream recipe presumes the operator pre-consolidates fuel; we serve operators whose wallets organically split into many small UTxOs, and consolidation forces a wasted on-chain tx. The intent.json wallet block stays a strict superset of the bash semantics — `wallet.txIn` continues to be the single fuel-and-collateral UTxO; `wallet.extraTxIns` is purely additive. Bash readers that ignore unknown JSON fields stay compatible.
- **II. Pure builders, impure shell.** Aggregation algorithm is pure; `swapProgram` change adds `forM_ siExtraWalletInputs (void . spend)` and remains pure. The `ResolverEnv` IO surface is unchanged — `reEnvQueryWalletUtxos` already returns `[(Text, Integer, Bool)]`. Pass.
- **III. Pluggable data source, local-node default.** No backend change. Pass.
- **IV. Build, never sign or submit.** No change to the build/sign boundary. Pass.
- **V. Test-first with golden CBOR fixtures.** Tests written first (P1 path: a new `Tx/SwapSpec.hs` case asserting body inputs include all selected UTxOs and collateral is the head; P2 path: `Tx/SwapWizardSpec.hs` cases exercising aggregation + shortfall; P3 path: existing fixtures untouched, demonstrating backward compat). Compliant.
- **VI. Hackage-ready Haskell.** All new code carries Haddock on exports, `-Werror` clean, fourmolu 70-col, explicit export lists. Compliant.

**Verdict**: Pass with one declared divergence (principle I, justified above). No complexity-tracking entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/007-aggregate-wallet-utxos/
├── plan.md                  # This file
├── spec.md                  # Functional spec (already written)
├── research.md              # Phase 0: design decisions + alternatives
├── data-model.md            # Phase 1: WalletSelection / WalletJSON entity shape
├── contracts/
│   └── intent-schema.diff   # Phase 1: JSON-Schema delta vs main
├── quickstart.md            # Phase 1: operator smoke-test recipe
├── tasks.md                 # Phase 2 (/speckit.tasks output)
└── checklists/
    └── requirements.md      # Spec quality checklist (already written)
```

### Source Code (repository root)

```text
amaru-treasury-tx/
├── lib/Amaru/Treasury/
│   ├── IntentJSON.hs                  # +wjExtraTxIns; translateSwap reads it
│   ├── IntentJSON/Schema.hs           # walletSchema gains optional extraTxIns
│   ├── TreasuryBuild.hs               # runSwap includes extras in inputUtxos
│   └── Tx/
│       ├── Swap.hs                    # +siExtraWalletInputs; swapProgram spends them
│       └── SwapWizard.hs              # selectWallet → aggregator;
│                                      #   +wsExtraTxIns; +riChunkSizeLovelace;
│                                      #   +ResolverWalletShortfall;
│                                      #   +walletFeeSlackLovelace
├── app/
│   ├── amaru-treasury-tx/Main.hs      # passes riChunkSizeLovelace; updated tracing
│   └── swap-probe/Main.hs             # constructs SwapIntent with empty extras
├── docs/assets/intent-schema.json     # regenerated from intentJsonSchema
└── test/
    ├── unit/Amaru/Treasury/
    │   ├── IntentJSONSpec.hs          # genWallet rolls 0–3 extras
    │   ├── IntentJSONSchemaSpec.hs    # +case: intent with non-empty extras
    │   └── Tx/
    │       ├── SwapSpec.hs            # +case: extras spent + collateral=head
    │       └── SwapWizardSpec.hs      # selectWallet aggregation + shortfall cases
    └── fixtures/swap-wizard/
        └── env.json                   # walletSelection.extraTxIns: []
```

**Structure Decision**: Single-cabal-package layout (Option 1), already established by the repo. No structural change — this feature edits existing modules and adds tests and fixture lines.

## Complexity Tracking

No constitution violations to track. The single divergence (principle I) is documented in the Constitution Check section above with a written justification, as the principle requires.
