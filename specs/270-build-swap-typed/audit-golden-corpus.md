# T002 — Audit: existing swap golden corpus

Inventory at commit `188c2ca1`. The CLI byte-identity safety net.

## Existing fixture roots

| Directory                              | Purpose                                                                                                  |
|----------------------------------------|----------------------------------------------------------------------------------------------------------|
| `test/fixtures/swap/`                  | Frozen swap-build fixture (the canonical scenario). Drives `test/golden/SwapGoldenSpec.hs`.              |
| `test/fixtures/swap-wizard/`           | Frozen wizard-input fixture (answers + env → expected intent). Drives wizard spec tests.                 |
| `test/fixtures/swap-quote/`            | Frozen swap-quote fixture (separate concern, NOT in scope for `buildSwapTx`).                            |

## `test/fixtures/swap/` contents

| File                                       | Role                                                                                                           |
|--------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `intent.json`                              | Input — the typed `SwapIntent` (parsed via `SomeTreasuryIntent`) that the build consumes.                      |
| `pparams.json`                             | Input — protocol parameters frozen at fixture-capture time.                                                    |
| `exunits.json`                             | Input — script execution unit budget per redeemer.                                                              |
| `expected.cbor`                            | Pinned output — the CBOR-encoded unsigned Conway tx body.                                                       |
| `target.tx.json`                           | Pinned output — wraps `expected.cbor` plus metadata; the byte-identity comparator inside `SwapGoldenSpec`.     |
| `report.golden.json`                       | Pinned output — the structured `TxBuildOutput` envelope serialised as JSON (the `report.json` artifact).        |
| `report.golden.md`                         | Pinned output — human-rendered Markdown of the report.                                                          |
| `report.missing-required-fields.json`      | Negative input — used to exercise the report decoder's schema validation arm.                                   |
| `report.malformed-required-fields.json`    | Negative input — same family, different malformation.                                                           |
| `legacy/`                                  | Historical fixtures, not touched by current tests; left for archaeology.                                       |
| `provenance.md`                            | Operator notes on how the fixture was captured (cardano-cli command, env vars). Important for reproducibility. |

## Existing golden specs to consider

| Spec                                          | Today                                                                                            |
|-----------------------------------------------|--------------------------------------------------------------------------------------------------|
| `test/golden/SwapGoldenSpec.hs`               | Loads `intent.json`, runs `runFromIntent` against the frozen `ChainContext`, byte-diffs CBOR vs `expected.cbor`. **This is exactly the byte-identity gate I need.** |
| `test/golden/ReportRenderSwapGoldenSpec.hs`   | Renders the success/failure report to the human-Markdown form against `report.golden.md`.        |
| `test/unit/Amaru/Treasury/Wizard/SwapSpec.hs` | Unit tests over the wizard (intent assembly).                                                     |
| `test/unit/Amaru/Treasury/Tx/SwapSpec.hs`     | Unit tests over the swap intent → tx translation (pure layer).                                    |
| `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` | Wizard-side behaviour tests (CLI plumbing).                                                       |

## Implications for tasks

- **T012 (`BuildSwapGoldenSpec.hs`)** is largely a **rebinding** of `SwapGoldenSpec.hs` against the new `Wizard.Swap.buildSwapTx` entry point instead of `runFromIntent`. If we ensure `buildSwapTx` produces a `TxBuildSuccess` whose `tbsTxCbor` equals what `runFromIntent` (the legacy entry) produces for the same `intent.json + frozen ChainContext`, the existing fixture is the baseline. **Zero new fixtures needed.**
- The TDD red→green for T012 is: write the new spec first, expect it to either (a) fail to compile (if `buildSwapTx` doesn't exist yet, which is T008's job) or (b) compile + byte-diff (if `buildSwapTx` exists but diverges). Either way: red before T008 and T015 turn it green.
- **T013 (sysexits roundtrip)**: there is no existing fixture for known-broken inputs producing exit 64/69/70. We synthesise these by mutating `intent.json` (e.g. delete a required UTxO reference for 64-class, point at a wrong network for 69-class, etc.) and pin the expected exit code. Keep new fixtures under `test/fixtures/swap/broken/{64,69,70}/intent.json`.

## Baseline byte-identity contract

For the swap fixture under `test/fixtures/swap/`, the canonical input is `intent.json` plus the frozen chain state. The canonical output is `expected.cbor`. The audit asserts:

- `intent.json` hash (sha256): captured here for traceability — `cd /code/amaru-treasury-tx-issue-269 && sha256sum test/fixtures/swap/intent.json` at the start of implementation.
- `expected.cbor` hash (sha256): same.
- `report.golden.json` hash (sha256): same.

These three hashes MUST not change across the refactor. The acceptance gate is unchanged-hashes plus all existing `SwapGoldenSpec.hs` tests green.

## Conclusion

The swap golden corpus is **one frozen scenario** (`test/fixtures/swap/`). Adequate as the byte-identity safety net. The refactor does not require new fixture capture; it just rebinds the existing golden spec against `buildSwapTx`.
