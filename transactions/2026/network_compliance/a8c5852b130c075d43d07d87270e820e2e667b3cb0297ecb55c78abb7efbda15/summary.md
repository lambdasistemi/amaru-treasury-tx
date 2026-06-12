# a8c5852b… — network_compliance swap, 2 × 10,000 USDM (20k total), ~116,279 ADA → ≥20,000 USDM @ floor 0.172

**Status:** submitted and confirmed on-chain (block 13,541,331, epoch 636); two SundaeSwap V3 orders now open on pool `64f35d26…`, awaiting scoop.

CLI: `amaru-treasury-tx 0.2.19.0` · cardano-tx-tools: `tx-inspect 0.2.3.0` / `tx-validate 0.2.3.0` (`/code/cardano-tx-tools` @ `f5bed57`).

## On-chain receipt

- **txid:** `a8c5852b130c075d43d07d87270e820e2e667b3cb0297ecb55c78abb7efbda15`
- **submitted:** 2026-06-12T18:00:44Z via `amaru-treasury-tx submit`, accepted by local mainnet n2c socket (`submit: accepted a8c5852b…`).
- **inclusion confirmed:** block **13,541,331** / slot **189,720,368** / **2026-06-12T17:50:59Z** (Koios `tx_info`). Cross-checked via `cardano-cli` UTxO query showing `a8c5852b…#0` and `a8c5852b…#1` live at the swap-order address.
- **fee:** 0.433688 ADA (433,688 lovelace). **valid_contract:** true.

## Intent

- **Scope:** network_compliance
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef`).
- **Mode:** 2 swap orders (the "20k in 2 swaps" split), both in this single tx.
  - Order #1: offer 58,139.534884 ADA → min 10,000.000001 USDM → destination network_compliance treasury.
  - Order #2: offer 58,139.534883 ADA → min 10,000.000000 USDM → destination network_compliance treasury.
- **USDM asset:** `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad` / `0014df105553444d`.
- **Floor rate:** 0.172 USDM/ADA (10,000 / 58,139.53) — an at-market floor (0% slippage) for ADA ≈ $0.172.
- **Total ADA committed to orders:** ~116,279.07 ADA (orders + 2 × Sundae fee 1,280,000 + per-order overhead).
- **Treasury / wallet UTxOs consumed:** `68ec097b…#3` (treasury) and `68ec097b…#4` (wallet); collateral `68ec097b…#4`.
- **Treasury leftover output:** 781,917.960233 ADA returned to the `network_compliance` treasury (`addr1xyezq8w…`).
- **Wallet change:** 79.858910 ADA back to the operator wallet (`addr1qx9aqvsf6gne…`, `8bd03209`).

## Money-flow verification (all proceeds → treasury)

Decoded from each order's datum, not just the stake credential:

- out 0 / out 1 (swap orders): payment = `amaru.swap.v2` (`fa6a58bb…`), **stake = treasury** (`32201dc1…`); each order's **destination = network_compliance treasury** ✓.
- out 2 (leftover, 781,917.96 ADA): payment + stake = treasury (`32201dc1…`) ✓.
- out 3 (79.86 ADA): operator wallet's own change/fuel — the only non-treasury output.

No funds route to any non-treasury address.

## Signer roster

`Disburse` policy `approved_by_owner_and_someone_else` (owner + one other scope owner):

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key).
- `7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb` (core_development owner — co-signer).

Both witnesses verified Ed25519-valid over the body hash `a8c5852b…` before assembly; final `tx-validate` on `signed-tx.hex` reported `structurally clean: 0 witness-completeness failures`.

## Provenance & metadata repair

The unsigned transaction was built off this host and provided to the operator session (no wizard run here, hence no `intent.json`). In transit, one byte of the metadata token name was corrupted — `ADA` → `ADD` (`0x41`→`0x44`) — producing a phase-1 `ConflictingMetadataHash`: the body commits to the canonical aux hash `443fc768…` ("Swap ADA…"), but the attached metadata hashed to `624ddce9…` ("Swap ADD…").

Repair: the single byte was restored to `ADA`, after which the attached metadata hashes to `443fc768…`, byte-identical to the canonical network_compliance swap metadata and matching the body's commitment. The **body was not modified**, so the core_development witness produced over the original body remained valid. The archived `tx.cbor` / `signed-tx.*` are the repaired, submitted bytes.

## Rationale (metadata)

- **event:** disburse
- **label:** Swap ADA<->USDM
- **destinationLabel:** network_compliance
- **description:** Swap ADA to 20k USDM
- **justification:** Convert treasury ADA balance

## Cross-references

- Parent input bundles in `inputs/` (5): `68ec097b…` (treasury + wallet spend), plus reference scripts `11ace24a…` (scope owners), `25ba96f5…` (permissions), `810bfcbde8…` (treasury script), `e7b395a9…` (registry). Each `inputs/<txid>.cbor` satisfies `blake2b-256(body) == <txid>`.
