# Plan — Distribute swap-order remainder

Spec: [spec.md](spec.md) · Issue: [#91](https://github.com/lambdasistemi/amaru-treasury-tx/issues/91).

## Design Decisions

### D1. Single pure helper `chunkLovelaces`; both `mkChunks` and `chunkCountFor` delegate to it.

Having two implementations of the same shape rule (one in `mkChunks`, one in `chunkCountFor`) is what made today's situation slip past tests — the count and the list could diverge under refactor. The new shape: one `chunkLovelaces` function, `mkChunks` maps each element to a `SwapOrderOut`, `chunkCountFor = length . chunkLovelaces`.

### D2. "Distribute when `rem < full`" is the single rule, no threshold.

Considered alternatives:

- **Fold-when-below-`extraPerChunkLovelace`-threshold**: requires plumbing the threshold to the chunk emitter and adds a magic number to reason about.
- **Always distribute**: changes `--chunk-usdm` semantics when the operator's chosen size leaves a substantial remainder — chunks would silently inflate. Rejected because the contract of `--chunk-usdm X` is "every chunk is X".

The `rem < full` rule preserves `--chunk-usdm` exactly (in practice `rem ≥ full` for all sensible chunk-usdm inputs) and only fires when distribution is uniform (each chunk grows by at most 1 lovelace), which is exactly the dust case.

### D3. USDM scaling is automatic.

`mkChunks` already computes USDM per chunk via `usdm n = (n * rNum + rDen - 1) \`div\` rDen`. With `chunkLovelaces`, the `+1` chunks scale by an extra `(rNum + rDen - 1) \`div\` rDen` USDM, which is at most 1 USDM smallest-unit at typical rates — negligible economically and exactly what the operator asked for ("chunk this lovelace value into N near-equal chunks").

### D4. Existing golden fixture stays byte-identical.

The current fixture inputs land in the `rem ≥ full` branch (`rem = 8,163,265,306`, `full = 32`). No goldens change. We add new unit cases for the distribute branch.

### D5. Gate.

`nix develop -c just ci` plus a live mainnet re-run before push. The re-run is the same probe-style swap-wizard | tx-build command used in #91's repro section.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `chunkCountFor` is exported and used by `Tx/SwapQuote.hs` via `generatedChunkCount`. The new behaviour might surface in swap-quote's affordability arithmetic. | Same delegation: `chunkCountFor = length . chunkLovelaces`. Treasury required-funding still equals `amount + chunkCount * extraPerChunkLovelace`. Affordability test goldens use `rem ≥ full` inputs (we'll check) and stay unchanged. |
| `mkChunks`' USDM-per-chunk math scales by `chunkLovelace`; the `+1` chunks emit an extra `~0–1` smallest-USDM unit each. Sundae datums change accordingly. | Acceptable: the operator's intent is "chunks summing to `amount`"; the `+1` is below USDM dust. Existing fixture is unaffected. |
| `chunkCountFor` callers expect `full + (rem > 0 ? 1 : 0)`. If a downstream consumer reads "chunk count" but relies on the old shape, the migration could break it. | Grep audit: `chunkCountFor` callers are `Tx/SwapQuote.hs` (one site) and the swap resolver (one site). Both consume the count as a multiplier on `extraPerChunkLovelace`; both stay correct under the new rule. |
| Property-test slow with arbitrary `Integer`. | Bound `amount` and `chunkSize` to `Positive (Integer)` with `arbitrarySizedNatural` or similar — fast. |

## Slice Plan (one vertical commit)

The entire fix is one bisect-safe slice.

### S1 — `chunkLovelaces` + matching `mkChunks` + `chunkCountFor`

- **RED**: new unit cases in `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`:
  1. dust-fold case: `chunkLovelaces 408_163_265_306 12_368_583_797 == [12_368_583_798, 12_368_583_798, 12_368_583_798, 12_368_583_798, 12_368_583_798] ++ replicate 28 12_368_583_797` (length 33, sum 408_163_265_306).
  2. clean-divide: `chunkLovelaces 100 25 == [25,25,25,25]`.
  3. tiny amount: `chunkLovelaces 7 2 == [3, 2, 2]` (`rem 1 < full 3` → distribute).
  4. chunk-usdm shape (existing fixture inputs): `chunkLovelaces 408_163_265_306 12_500_000_000 == replicate 32 12_500_000_000 ++ [8_163_265_306]`.
  5. QuickCheck `sum (chunkLovelaces a c) == a` for `a, c > 0`.
- **GREEN**: replace `mkChunks` body to call `chunkLovelaces` and map each element to a `SwapOrderOut`; rewrite `chunkCountFor = toInteger . length . chunkLovelaces (amount c) c`.
- **Bisect-safe**: yes — all callers consume `chunkCountFor` as a multiplier on `extraPerChunkLovelace`; sum invariant is preserved; existing fixture is unchanged.

**Commit message**: `fix(091): distribute swap-order remainder; no dust outputs`.

## Live re-verification

Before push:

```bash
mkdir -p /tmp/swap-091-final
CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket \
  cabal run -v0 -O0 exe:amaru-treasury-tx -- \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-wizard --wallet-addr addr1q802wxt6c… --metadata /code/metadata-mainnet.json \
      --scope network_compliance --usdm 100000 --split 33 --min-rate 0.245 \
      --description "…" --justification "…" --destination-label "…" \
      --extra-signer core_development \
      --out /tmp/swap-091-final/intent.json
# Expected: 33 swap-order outputs, no 5-lovelace dust.
```

Then `cabal run -v0 -O0 exe:amaru-treasury-tx -- tx-build --intent /tmp/swap-091-final/intent.json` and `jq` the output count — must be 35 (33 swap-orders + treasury leftover + wallet change).

## Gate

`specs/091-distribute-chunk-remainder/gate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nix develop --quiet -c just ci
```
