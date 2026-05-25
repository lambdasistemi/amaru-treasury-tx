# Tasks: swap-wizard `--all-ada` consumes mixed UTxOs

**Feature**: 291-swap-mixed-utxos
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Two bisect-safe slices.  Each commit body trailer: `Tasks: T291-S<n>`.  Persistent driver pane re-pointed at `/code/amaru-treasury-tx-issue-291/`.

## Slice A — `planAllAda` extension + property test

- [ ] T291-S1 [US1, US2, US3] Drop the `not hasNativeAssets` filter on `pureInputs` in `lib/Amaru/Treasury/Tx/SwapWizard.hs` (≈ line 1048).  Rename `pureInputs` → `selectedInputs`.  Compute `available :: Integer` (the lovelace sum) over `selectedInputs`.

- [ ] T291-S1 Extend `AllAdaPlan` (≈ line 310) with a new field `aapContinuingNativeAssets :: NativeAssetsBundle` (or use the project's existing native-assets carrier type — check `cardano-tx-tools` / `Cardano.Tx.Build`).  The bundle aggregates non-ADA assets summed across `selectedInputs`.  Empty bundle when all selected inputs are pure-ADA.

- [ ] T291-S1 RED: extend `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` with a unit test that constructs a synthetic mixed-input set and asserts `planAllAda` returns `Right` with `aapContinuingNativeAssets` non-empty and equal to the input bundle sum.  Run, observe failing.

- [ ] T291-S1 RED: extend the same Spec with a unit test that synthesises 3 mixed UTxOs summing to 4 ADA + USDM and `--split 1` → `planAllAda` returns `Left (AllAdaInsufficientLovelace 4000000 5280001)`.  Run, observe failing.

- [ ] T291-S1 RED: add a QuickCheck property `prop_planAllAda_nativeAssetConservation` — for any random `[treasuryUtxo]` input, the sum of native-asset quantities in `aapContinuingNativeAssets` of the returned plan equals the sum across `selectedInputs`.  Run, observe failing.

- [ ] T291-S1 GREEN: implement the changes above.  All new tests + the existing unit suite pass.  The full golden corpus passes byte-for-byte (Constitution Principle V).

- [ ] T291-S1 Smoke: `nix build .#default && ./result/bin/amaru-treasury-tx swap-wizard --metadata test/fixtures/metadata.json --scope <scope> --all-ada …` against a fixture with mixed UTxOs — confirm the intent.json carries non-empty `continuingNativeAssets` (when slice B's encoder change lands; in slice A the field is computed but not yet serialised — note this in WIP.md).

- [ ] T291-S1 Commit: `feat(291): planAllAda consumes mixed UTxOs + native-asset conservation property` with `Tasks: T291-S1` trailer.

## Slice B — TxBuild output wiring + golden fixture

- [ ] T291-S2 [US1] In `lib/Amaru/Treasury/Wizard/Swap.hs` (or wherever the swap tx-build consumes `AllAdaPlan`): emit a continuing treasury output at the scope's treasury address when `aapContinuingNativeAssets` is non-empty.  Value: `aapLeftoverLovelace lovelace + aapContinuingNativeAssets`.  When empty: emit no continuing output (preserves byte-for-byte parity with today's pure-ADA leftover).

- [ ] T291-S2 [US1, US2] Extend `lib/Amaru/Treasury/IntentJSON.hs` (or equivalent encoder) so the swap intent's JSON carries `continuingNativeAssets` ONLY when non-empty.  Pure-ADA scopes emit byte-identical intent.json (FR-008).

- [ ] T291-S2 RED: add the new golden corpus `test/fixtures/swap-all-ada-from-mixed/` with:
  - `intent.json` (synthesised from the network_compliance state at slot 188143808: 5 UTxOs per issue #291, target `--all-ada --split 1 --min-rate 0.24`).
  - The corresponding `tx.cbor.hex` (golden, ExUnits stripped per Principle V).
  - `report.json` (golden — txid, fee, ExUnits per script, redeemer indexes).

  Without slice B's wiring landed, the corpus's golden tests fail (the produced CBOR differs from the recorded golden because the continuing treasury output is missing).  Observe RED.

- [ ] T291-S2 GREEN: implement the tx-build wiring + the intent.json encoder change.  Run the full golden suite — the new fixture passes byte-for-byte AND every existing pure-ADA golden passes unchanged (FR-002 / SC-002).

- [ ] T291-S2 Smoke: against the `network_compliance` scope's live state, regenerate the intent.json with the operator's exact command from issue #291.  Confirm:
  - The intent.json carries `continuingNativeAssets: { usdm: 6381618692, otherAssets: [] }`.
  - The intent.json's swap chunk has the computed pure-ADA chunk amount (sum of all 5 input lovelace, minus per-chunk overhead, minus min-UTxO floor, minus the leftover that flows into the continuing output's ADA portion).
  - The build path produces unsigned CBOR (Principle IV — never sign or submit).

- [ ] T291-S2 Commit: `feat(291): swap-wizard tx emits continuing treasury output for mixed-UTxO consumption + golden fixture` with `Tasks: T291-S2` trailer.

## Dependencies

- Slice A blocks B.  B consumes A's `aapContinuingNativeAssets` field.
- Each slice is bisect-safe: A landed alone is a no-op plan extension (no tx output change); B adds the output + new golden corpus.

## Gate

```bash
nix build --quiet .#default .#checks.x86_64-linux.unit .#checks.x86_64-linux.lint
```

Plus golden corpus passes byte-for-byte (Constitution Principle V's NON-NEGOTIABLE proof).
