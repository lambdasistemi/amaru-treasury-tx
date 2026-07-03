# 4fdd9cd0… — ops_and_use_cases swap, 8 × 5,000 USDM (40k total), ~233,944 ADA → ≥40,000 USDM @ floor 0.171

**Status:** submitted and confirmed on-chain (block 13,630,628, epoch 640); eight SundaeSwap V3 orders open on pool `64f35d26…`, awaiting scoop. First swap executed from the ops_and_use_cases scope treasury (first entry in this directory).

CLI: `amaru-treasury-tx 0.2.19.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `4fdd9cd08ce3a1b8ccea8f2e56825bc02591285e57b1db60b6b0360b913e6fdb`
- **submitted:** 2026-07-03 via `amaru-treasury-tx submit` from this host (`submit: accepted 4fdd9cd0…`, see `submit.log`), after a final clean `tx-validate` immediately before broadcast.
- **inclusion:** block **13,630,628** / slot **191,528,956** / **2026-07-03T13:34:07Z** (Blockfrost `/txs`), epoch 640.
- **fee:** 0.550026 ADA (550,026 lovelace). **valid_contract:** true.

## Intent

- **Scope:** ops_and_use_cases. (The required-signer pairing with `8bd03209` led the session to initially frame this as network_compliance; on-chain data — funding UTxO, all reference inputs, and every destination credential — proves ops_and_use_cases, confirmed by the operator. The metadata's destination label also reads `ops_and_use_cases`.)
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef`), 8-way order split.
  - Each order: offer ≈29,243.046082 ADA → min 5,000.000001 USDM (last order 5,000.000000), destination ops_and_use_cases treasury (`46746c64…`).
- **USDM asset:** `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad` / `0014df105553444d`.
- **Floor rate:** ≈0.171 USDM/ADA, in line with the Jun-12 precedent's 0.172.
- **Total ADA committed to orders:** ~233,970 ADA (233,944.37 offers + 8 × 1.28 scooper fee + 8 × 2 ADA deposit).
- **UTxOs consumed:** `68ec097b…#2` (ops_and_use_cases treasury, 1,397,011.200000 ADA) and `207038cf…#5` (operator wallet change from the companion swap, 79.385980 ADA); collateral `207038cf…#5`.
- **Treasury leftover output:** 1,163,066.831345 ADA back to the ops_and_use_cases treasury.
- **Wallet change:** 78.835954 ADA back to the operator wallet (`8bd03209`) = wallet input − fee.
- **Rationale (metadata):** event `disburse`, label `Swap ADA<->USDM`, description `Swap ADA to 40k USDM`, justification `Convert remaining treasury ADA balance`.

## Rebuild history (stale first candidate)

The first fully-witnessed candidate for this swap (predicted txid `c638d21d7d3f6b3baea1fd82b0f61bb06d2ede96c0596d032ffa0d374cbae004`) spent `a8c5852b…#3` as its wallet/collateral input. The companion swap `207038cf…` consumed that UTxO on-chain first, so the candidate went stale before broadcast — caught by re-running `tx-validate` against the live node (`BadInputsUTxO` + collateral cascade), never submitted, and abandoned. This tx is the rebuild: same intent, wallet input re-sourced from `207038cf…#5` (the companion's own change), freshly witnessed by both signers.

## Money-flow verification

Value conserved exactly: 1,397,090.585980 ADA in = orders + leftover + wallet change + fee. Decoded from each order's datum: all eight destinations are the ops_and_use_cases treasury stake credential (`46746c64…`); cancel authority is the four scope owners; the only non-treasury output is the operator wallet's own change. Independently reviewed pre-submit by a cold-context agent (live input resolution, ledger, roster, TTL ≈47.9 h, byte-identical `attach-witness` reconstruction): GO on all mechanical gates.

## Signer roster

`Disburse` policy `approved_by_owner_and_someone_else`:

- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner)
- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key — co-signer)

Both detached witnesses verified structurally and by `tx-validate` (`witness_completeness_count: 0`, zero structural failures); final pre-submit validation immediately before broadcast was clean.

## Provenance & missing files

The unsigned transaction was built off this host and provided to the operator session (no wizard run here, hence **no `intent.json` / `wizard.log` / `build.log` / `report.json`**). Witnesses were produced remotely and delivered to the session; assembly, validation, submission, and this archive ran here. The archived `signed-tx.hex` body hashes (blake2b-256) to the on-chain txid.

## Cross-references

- Parent input bundles in `inputs/` (6): `68ec097b…` (ops treasury funding), `207038cf…` (companion swap providing the wallet input — archived at `transactions/2026/network_compliance/207038cf…`), plus reference scripts `11ace24a…` (scope owners), `25ba96f5…` (permissions), `660c0729…` (treasury script), `e7b395a9…` (registry). Each `inputs/<txid>.cbor` satisfies `blake2b-256(canonical(body)) == <txid>`.
- The stale abandoned candidate (`c638d21d…`) was never submitted and is intentionally not archived as an entry; its story is recorded here.
