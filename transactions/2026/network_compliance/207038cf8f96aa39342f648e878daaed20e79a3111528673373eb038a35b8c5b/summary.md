# 207038cf… — network_compliance swap, 4 × 5,000 USDM (20k total), ~118,343 ADA → ≥20,000 USDM @ floor 0.169

**Status:** submitted and confirmed on-chain (block 13,630,569, epoch 640); four SundaeSwap V3 orders open on pool `64f35d26…`, awaiting scoop; leftover `#4` (663,561.64 ADA) and the four pending orders confirmed live via `treasury-inspect` in the same operator session.

CLI: `amaru-treasury-tx 0.2.19.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `207038cf8f96aa39342f648e878daaed20e79a3111528673373eb038a35b8c5b`
- **inclusion:** block **13,630,569** / slot **191,527,861** / **2026-07-03T13:15:52Z** (Blockfrost `/txs`), epoch 640.
- **fee:** 0.472930 ADA (472,930 lovelace). **valid_contract:** true.
- **submitter:** external co-signing session — this operator host prepared and witnessed the tx but did not broadcast it; it appeared on-chain during the session and the receipt is backfilled from Blockfrost. No local `submit.log` exists for this entry.

## Intent

- **Scope:** network_compliance
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef`), 4-way order split (2 pairs differing by 1 lovelace — integer-division remainder of an even split).
  - Each order: offer ≈29,585.798817 ADA → min 5,000.000001 USDM (last order 5,000.000000), destination network_compliance treasury (`32201dc1…`).
- **USDM asset:** `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad` / `0014df105553444d`.
- **Floor rate:** ≈0.1690 USDM/ADA — continues the archive's declining band: 0.245 (May 21), 0.172 (Jun 12, parent tx `a8c5852b…`), 0.169 here.
- **Total ADA committed to orders:** ~118,343.20 ADA (offers + 4 × 1.28 Sundae scooper fee + 4 × 2 ADA deposit).
- **UTxOs consumed:** `a8c5852b…#2` (treasury leftover, 781,917.960233 ADA) and `a8c5852b…#3` (operator wallet change, 79.858910 ADA); collateral `a8c5852b…#3`.
- **Treasury leftover output:** 663,561.644967 ADA back to the network_compliance treasury.
- **Wallet change:** 79.385980 ADA back to the operator wallet (`8bd03209`) = wallet input − fee (fee funded from the wallet, not the treasury).

## Money-flow verification

Value conserved exactly: 781,997.819143 ADA in = orders + leftover + wallet change + fee. Decoded from each order's datum: all four destinations are the network_compliance treasury stake credential (`32201dc1…`); cancel authority is the four scope owners. The only non-treasury output is the operator wallet's own change. Independently reviewed pre-submit by a cold-context agent (inputs/outputs ledger, roster, TTL, byte-identical `attach-witness` reconstruction): GO, with the floor rate flagged for explicit operator confirmation — given.

## Signer roster

`Disburse` policy `approved_by_owner_and_someone_else`:

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key)
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner — co-signer)

Both detached witnesses verified structurally (`[vkey(32), sig(64)]`) and by `tx-validate` (`witness_completeness_count: 0`, zero structural failures) before assembly; final phase-1 pre-flight was clean against the live node.

## Provenance & missing files

The unsigned transaction was built off this host and provided to the operator session (no wizard run here, hence **no `intent.json` / `wizard.log` / `build.log` / `report.json`**). Witnesses were produced remotely and delivered to the session; assembly (`attach-witness`) and all validation ran here. The archived `signed-tx.hex` body hashes (blake2b-256) to the on-chain txid. Broadcast happened externally — **no `submit.log`** (see receipt above).

## Cross-references

- Parent input bundles in `inputs/` (5): `a8c5852b…` (treasury + wallet spend; the Jun-12 predecessor swap in this same directory tree), plus reference scripts `11ace24a…` (scope owners), `25ba96f5…` (permissions), `810bfcbd…` (treasury script), `e7b395a9…` (registry). Each `inputs/<txid>.cbor` satisfies `blake2b-256(canonical(body)) == <txid>`.
- Companion follow-on swap in the same session: `transactions/2026/ops_and_use_cases/4fdd9cd0…` — spends this tx's output `#5` as its wallet/collateral input.

Note on byte provenance: `blake2b-256(body) == txid` holds for the archived `signed-tx.hex` (the binding check). A full-byte diff against Blockfrost's `/txs/{hash}/cbor` shows witness-set encoding differences — expected, since blocks store transaction components segregated and Blockfrost reconstructs the full tx; the reconstruction is not the submitted byte stream.
