# Feature Specification: `swap-wizard --all-ada` consumes mixed UTxOs

**Feature Branch**: `291-swap-mixed-utxos`
**Issue**: [#291](https://github.com/lambdasistemi/amaru-treasury-tx/issues/291)
**Created**: 2026-05-25
**Status**: Draft

## Goal

Make `swap-wizard --all-ada` usable on scopes whose treasury has been heavily swapped to USDM.  Today the wizard refuses (`AllAdaInsufficientLovelace`) when pure-ADA treasury UTxOs sum below the per-build minimum, even though the scope holds plenty of ADA locked alongside USDM in mixed UTxOs.  The fix: let the swap tx ALSO consume mixed UTxOs, routing their ADA into the swap-order outputs and returning their non-ADA assets (USDM, anything else) into one continuing treasury output.

A single tx becomes both a swap and a reorganize.  No change to the operator command surface — `--all-ada` is just more comprehensive.

## User Stories

### User Story 1 — Swap ADA from a treasury that's mostly USDM (P1)

Operator on the `network_compliance` scope has 129 ADA across the treasury, but only 2 ADA of that is in a pure-ADA UTxO; the other ~127 ADA is locked alongside 6.38B USDM in four mixed UTxOs.  They run:

```bash
amaru-treasury-tx swap-wizard \
  --scope network_compliance \
  --all-ada --split 1 \
  --min-rate 0.24 \
  --validity-hours 48 \
  --description "Swap ada" \
  ...
```

The wizard succeeds.  The tx consumes all five treasury UTxOs, sends ~125 ADA (minus the leftover floor and per-chunk overhead) to a single swap order at SundaeSwap, and emits one continuing treasury output carrying all 6.38B USDM + the min-UTxO ADA leftover.

**Independent test**: against the recorded state at slot 188143808 (5 UTxOs as in issue #291), the wizard produces an intent.json with:

- One `swap` order chunk containing the computed pure-ADA chunk amount.
- One `continuing` treasury output containing `6,381,618,692` USDM + the configured min-UTxO leftover.
- Total non-ADA assets in the output exactly equal the sum across inputs (no native asset loss).

### User Story 2 — Backwards compatibility for pure-ADA scopes (P1)

A scope whose treasury holds ONLY pure-ADA UTxOs (e.g., freshly-funded, no buys yet) sees byte-identical behaviour to today's `--all-ada`.  The continuing output is omitted when the input bundle carries no native assets — same as the existing leftover.

**Independent test**: every existing golden CBOR fixture (covering pure-ADA ADA disburse, USDM disburse, reorganize, withdraw) passes byte-for-byte after the change.  This is Constitution Principle V's NON-NEGOTIABLE guard.

### User Story 3 — Total-ADA insufficient still fails honestly (P1)

When the scope's total ADA (mixed + pure) is genuinely insufficient for the requested split + overhead + min-UTxO floor, `AllAdaInsufficientLovelace` still fires with the same constructor — `available` now reports the sum across all UTxOs, not just pure-ADA.

**Independent test**: synthetic state with 3 mixed UTxOs summing to 4 ADA + 1B USDM and `--split 1` (requires ≥5.28 ADA) → wizard fails with `ResolverAllAdaFailed (AllAdaInsufficientLovelace 4000000 5280001)`.

## Functional Requirements

- **FR-001**: `planAllAda` no longer filters inputs by `not hasNativeAssets`.  `pureInputs` is renamed to `selectedInputs` and includes every candidate treasury UTxO.

- **FR-002**: `AllAdaPlan` extends with `aapContinuingNativeAssets :: NativeAssetsBundle` — the bundle of USDM + other native assets to carry into the continuing treasury output.  When zero, no continuing output is emitted (preserves existing pure-ADA behaviour).

- **FR-003**: `available :: Integer` (the lovelace sum) is computed across all selected inputs.  The pre-flight inequality `available < minimumForOneLovelace` (resp. `minimumForRequestedSplit`) still fires `AllAdaInsufficientLovelace` with `available` reflecting the new total.

- **FR-004**: The TxBuild output construction (in `Wizard.Swap`) consumes `aapContinuingNativeAssets`:
  - When non-empty: emit one continuing treasury output at the scope's treasury address, value = `aapLeftoverLovelace lovelace + aapContinuingNativeAssets`.
  - When empty: emit no continuing output (matches existing pure-ADA leftover behaviour).

- **FR-005**: Total non-ADA assets conservation: for any successful build, the sum of native-asset quantities in the inputs equals the sum in the outputs.  No burn, no mint, no asset loss.  This is a property test (Constitution Principle V's "property" type).

- **FR-006**: Constructor `AllAdaError` remains unchanged.  `AllAdaInsufficientLovelace` keeps its existing signature `AllAdaInsufficientLovelace !Integer !Integer` (available, required).  The semantics shift (available is now total, not pure-only) but the type doesn't.

- **FR-007**: Golden CBOR fixture set extends with:
  - `test/fixtures/swap-all-ada-from-mixed/intent.json` (input).
  - `test/fixtures/swap-all-ada-from-mixed/tx.cbor.hex` (golden — excluding ExUnits per Principle V).
  - `test/fixtures/swap-all-ada-from-mixed/report.json` (golden).

  Sourced from a synthesised treasury matching the network_compliance state at slot 188143808 (5 UTxOs as enumerated in issue #291).

- **FR-008**: The intent.json shape gains an optional `continuingNativeAssets` field on the swap intent (only present when non-empty).  No backend / CLI change needed — `/operate` continues to work because it doesn't model this field.

## Success Criteria

- **SC-001**: Running the user's exact command from issue #291 against `network_compliance` at slot 188143808 produces a valid intent.json that builds successfully (no `AllAdaInsufficientLovelace`).
- **SC-002**: Every existing golden CBOR fixture passes byte-for-byte (no behaviour drift on pure-ADA scopes).
- **SC-003**: The new `swap-all-ada-from-mixed` golden passes byte-for-byte across the corpus.
- **SC-004**: Property test: native-asset conservation holds for every randomly-generated treasury state.
- **SC-005**: Build Gate green at HEAD.

## Out of scope

- `disburse-wizard` / `reorganize-wizard` mixed-UTxO behaviour (already correct — they merge or carry forward).
- USDM→ADA swap (the inverse direction; uses `--all-usdm` or amount-mode flags).
- A new operator flag.  `--all-ada` is the single mode; its semantics widen.
- Multi-asset support beyond USDM + lovelace (the existing `otherAssets` field continues to be carried as-is; no policy-specific code).
- Wallet-side changes.
- `--include-mixed` opt-in (the change is unconditional; pure-ADA scopes degrade to the old behaviour automatically).
