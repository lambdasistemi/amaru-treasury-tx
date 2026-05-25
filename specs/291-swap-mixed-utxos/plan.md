# Implementation Plan: swap-wizard `--all-ada` consumes mixed UTxOs

**Feature**: 291-swap-mixed-utxos
**Spec**: [`spec.md`](spec.md)

## Tech stack

- Haskell + cabal + Nix (matches `cardano-node-clients`).
- Plutus + cardano-ledger-conway for tx body construction.
- HSpec + golden CBOR fixtures + QuickCheck for properties (per Constitution Principle V).

## Affected modules

- `lib/Amaru/Treasury/Tx/SwapWizard.hs` — primary edit.
  - `AllAdaPlan` (≈ line 310): extend with `aapContinuingNativeAssets :: NativeAssetsBundle` (or analogous `Value` / `Map AssetClass Integer`, whichever the existing code uses for native-asset carrying).
  - `planAllAda` (≈ line 990): drop the `not hasNativeAssets` filter; compute `available` over all inputs; aggregate the native-asset bundle from selected inputs; thread through the new `aapContinuingNativeAssets` field.
- `lib/Amaru/Treasury/Wizard/Swap.hs` — consume the new field when building outputs: emit one continuing treasury output when the bundle is non-empty; otherwise skip (preserves byte-for-byte parity with pure-ADA scopes).
- `lib/Amaru/Treasury/IntentJSON.hs` (or equivalent) — extend the intent.json encoder with `continuingNativeAssets` field on the swap intent (optional, omitted when empty).
- `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` — extend with the new path's RED tests + native-asset conservation property.
- `test/fixtures/swap-all-ada-from-mixed/` — NEW golden corpus (intent.json + tx.cbor.hex + report.json).
- Existing goldens under `test/fixtures/swap-*/` — UNCHANGED.  Byte-for-byte regression check.

## Slicing

Two bisect-safe slices:

1. **Slice A — `planAllAda` extension + property test**: drop the pure-ADA filter; extend `AllAdaPlan` with `aapContinuingNativeAssets`; aggregate native assets from selected inputs.  Add a HSpec + QuickCheck property: native-asset conservation across `planAllAda` (total-in == total-out at the plan level).  Per-variant failure tests cover `AllAdaInsufficientLovelace` with mixed inputs.  No tx-build wiring yet — the new field is computed but unused.  Existing goldens still pass (no tx output change).

2. **Slice B — TxBuild output wiring + golden fixture**: consume `aapContinuingNativeAssets` in `Wizard.Swap`'s tx-build path.  When non-empty: emit a continuing treasury output at the scope's treasury address.  Add the `swap-all-ada-from-mixed` golden fixture (intent.json + tx.cbor.hex + report.json) covering the network_compliance state from issue #291.  Existing goldens MUST pass byte-for-byte.

Each slice = one commit with `Tasks: T291-S<n>` trailer.

## Constitution alignment

- Principle II (pure builders, impure shell): the plan extension is in `Tx.SwapWizard` (pure); the tx-build site is in `Wizard.Swap` consuming a `Backend`-injected resolver — boundary preserved.
- Principle IV (build, never sign or submit): unaffected — wizard still emits unsigned CBOR + JSON summary.
- Principle V (test-first with golden CBOR fixtures, NON-NEGOTIABLE): both slices ship golden fixtures or property tests; existing goldens pass byte-for-byte (FR-002, SC-002).
- Principle VI (Hackage-ready Haskell): `-Werror`, fourmolu 70-col, Haddock on every export, explicit export lists.
- Principle VII / VIII (1694 metadata, IPFS evidence): unaffected.

## Out-of-scope (mirrors spec)

- Other wizards' UTxO selection.
- USDM→ADA swap.
- New CLI flag (`--all-ada` semantics widen unconditionally).
- Asset-specific policy beyond the existing native-asset bundle abstraction.
