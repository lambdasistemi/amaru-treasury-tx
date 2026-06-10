# 77d687bc… — network_compliance swap #5, 40,816 ADA → ≥10,000 USDM @ floor 0.245

**Status:** submitted on-chain (block details pending indexer backfill); SundaeSwap scoop awaited. Two prior orders from `9f119393…` are also still unscooped — four total open orders on pool `64f35d26…` after this lands.

CLI: `amaru-treasury-tx 0.2.11.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `77d687bc713dd707e357fc0da992fe7eb02a6baadef0a1cbe029563b54b10a27`
- **submitted:** 2026-05-21T17:43:14Z via `amaru-treasury-tx submit`, accepted by local mainnet n2c socket.
- **inclusion confirmed at:** 2026-05-21T17:46Z — `tx-validate` against `signed-tx.hex` returned `ConwayMempoolFailure "All inputs are spent. Transaction has probably already been included"`. Tip at that check was slot 187,819,174 / block 13,447,654 / hash `33edc25a9c2f8870eb81c0503b5c84902a1e80293b688a4049a68d51267985c0`.
- **block / block_height / slot / block_time:** pending — local n2c only, no Blockfrost/koios available this session. Recorded in `submitted.json.inclusion_evidence`.
- **fee:** 0.436937 ADA (436,937 lovelace). **valid_contract:** true.

## Intent

- **Scope:** network_compliance
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef`).
- **Mode:** 2 chunks of 20,408,163,265 / 20,408,163,266 lovelace.
- **Min rate:** 0.245 USDM/ADA (245,000 / 1,000,000).
- **ADA committed to orders:** 40,816,326,531 lovelace (~40,816.327 ADA).
- **Net treasury debit:** 40,822,886,531 lovelace (orders + 2 × Sundae fee 1,280,000 + per-chunk overhead).
- **Treasury UTxO consumed:** `9f119393a85bb9aa0c94f8c649288dabb956b88dcbe055b10e741a2237123420#2` (164,177.113469 ADA — leftover from the immediately-prior swap `9f119393…`).
- **Wallet UTxO consumed:** `9f119393…#3` (91.704950 ADA).
- **Treasury leftover output:** 123,354,226,938 lovelace returned to `network_compliance` treasury (`addr1xyezq8w…`).
- **Wallet change:** 91,268,013 lovelace back to `addr1qx9aqvsf6gne…`.
- **Expected USDM at floor (both orders fill):** 10,000.000001 USDM total (5,000.000001 + 5,000.000000).

## Signer roster

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key).
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner — co-signer for `Disburse` policy `approved_by_owner_and_someone_else`).

## Rationale

- **event:** disburse
- **label:** Swap ADA<->USDM
- **destinationLabel:** Network Compliance treasury
- **description:** `Swap network_compliance ADA to USDM at floor 0.245`
- **justification:** Required to pay Antithesis as vendor.

## Pre-submit validation

- `tx-inspect 0.2.0.0` against `signed-tx.tx` with Amaru rules: rendered cleanly, all rule-collapsed labels (`amaru.swap-order`, treasury account, four owner hashes, USDM policy/asset) present and correct.
- `tx-validate 0.2.0.0 --output human` against the local mainnet n2c socket on the signed tx: `structurally clean: 0 witness-completeness failures filtered`.
- Independent fresh-context subagent recomputed the txid via blake2b-256 over the 1,501-byte body span of `signed-tx.tx`: matched `77d687bc…` exactly. Value conservation closes to the lovelace; recommendation **GO** with queue-position caveat (four open orders on the same pool at the same floor after this lands).

## Inputs/ bundle

- 5 parent CBORs archived under `inputs/`, each verified `blake2b-256(body(tx)) == filename`:
  - `11ace24a…` — scopes deployed-at reference (`#0`).
  - `25ba96f5…` — permissions deployed-at reference (`#2`).
  - `810bfcbd…` — treasury script deployed-at reference (`#0`).
  - `e7b395a9…` — registry deployed-at reference (`#2`).
  - `9f119393…` — parent tx (the immediately-prior swap that posted this tx's treasury input + wallet input + collateral). Sourced from `transactions/2026/network_compliance/9f119393…/signed-tx.hex` in the same branch.
- The four reference CBORs were copied byte-for-byte from the prior `9f119393…/inputs/` archive in this repo; the parent CBOR was lifted from this repo's own `9f119393…/signed-tx.hex` (the full Conway tx).

## Build provenance notes

- Workflow drove out of `/tmp/attx-172/swap-10k-network-compliance-3/`. A sibling `…-0244/` rundir holds an abandoned earlier build at floor 0.244 (operator rolled back to 0.245); not archived.
- 5th submitted network_compliance swap of the session (predecessors `a902aecd`/`d1068d4f`/`97110966`/`d5a6b515`/`037b8421` in branch history).

## Operator follow-ups

- Watch pool `64f35d26…` for scoops filling four orders: two from `9f119393…` (`#0`, `#1`) and two from this tx (`#0`, `#1`). Floor 0.245; at mid ≈ 0.250 expected delivery per order is ~5.1k USDM; downside floored at 5,000 USDM.
- Backfill `submitted.json` `block`, `block_height`, `slot`, `block_time` once Blockfrost/koios is available.
- Run the submitted-log completeness audit (per skill) on `/tmp/attx-172/*/submit.log` before declaring this submit session done.
