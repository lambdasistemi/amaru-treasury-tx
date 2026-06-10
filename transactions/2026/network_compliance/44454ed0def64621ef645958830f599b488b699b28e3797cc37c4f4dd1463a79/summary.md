# 44454ed0… — network_compliance terminal sweep, 41,705 ADA → ≥10,217.77 USDM @ floor 0.245

**Status:** submitted on-chain (block details pending indexer backfill); SundaeSwap scoop awaited. **Terminal pure-ADA-out swap for the scope** — after this scoops, the network_compliance treasury holds **2 ADA (min-UTxO bond)** until USDM lands from the scoop.

CLI: `amaru-treasury-tx 0.2.11.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `44454ed0def64621ef645958830f599b488b699b28e3797cc37c4f4dd1463a79`
- **submitted:** 2026-05-21T19:36:02Z via `amaru-treasury-tx submit`, accepted by local mainnet n2c socket.
- **inclusion confirmed at:** 2026-05-21T19:36:30Z — `tx-validate` mempool short-circuit. Tip: slot 187,825,880 / block 13,447,994 / hash `8d01766d28fa47d94bd5cd3ad0223981da7833431bc374fc6b08494398ecc500`.
- **block / block_height / slot / block_time:** pending indexer backfill (recorded in `submitted.json.inclusion_evidence`).
- **fee:** 0.471355 ADA. **valid_contract:** true.

## Intent

- **Scope:** network_compliance
- **Operation:** sweep ADA → USDM via SundaeSwap V3 (pool `64f35d26…`).
- **Mode:** `--all-ada --split 1` — single chunk, full treasury.
- **Min rate:** 0.245 USDM/ADA. (Rebuilt from a 0.246 attempt that sat above the realised band ~0.2457.)
- **Treasury UTxOs consumed:** `3ecffded…#2` (41,708.453876 ADA) + `488e5b41…#1` (2 ADA dust ancestor — desirable housekeeping collapse).
- **Wallet UTxO consumed:** `3ecffded…#3` (90.394139 ADA).
- **Sweep amount (committed to order):** 41,705.173876 ADA.
- **Treasury leftover output:** 2,000,000 lovelace (the **min-UTxO bond** — scope is now pure-ADA-empty modulo this 2 ADA).
- **Expected USDM at floor:** **≥10,217.7676 USDM**. At realised ~0.2457 band: ~10,246.96 USDM.

## Signer roster

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key).
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner — co-signer for Disburse policy).

## Rationale

- event: disburse · label: Swap ADA<->USDM · destinationLabel: Network Compliance treasury
- description: Sweep network_compliance ADA to USDM at floor 0.245
- justification: Required to pay Antithesis as vendor

## Pre-submit validation

- `tx-inspect 0.2.0.0` with Amaru rules: clean rule-collapsed tree (5,301 B; 1-chunk shape).
- `tx-validate 0.2.0.0 --output human` on signed tx: `structurally clean: 0 witness-completeness failures filtered`.
- Independent fresh-context subagent recomputed txid via blake2b-256 over 1,111-byte body span: matched `44454ed0…` exactly. Value conservation closes to zero. Both vkey witnesses verify cryptographically. Recommendation **GO** with depletion-flag acknowledgement.

## Inputs/ bundle

- 6 parent CBORs archived under `inputs/`, each verified `blake2b-256(body(tx)) == filename`:
  - `11ace24a…` — scopes deployed-at reference.
  - `25ba96f5…` — permissions deployed-at reference.
  - `810bfcbd…` — treasury script deployed-at reference.
  - `e7b395a9…` — registry deployed-at reference.
  - `3ecffded…` — predecessor tx (swap #7) lifted from this repo's own archive.
  - `488e5b41…` — earlier sweep that left the 2 ADA dust UTxO consumed here; lifted from this repo's prior archive (on-main via PR #174).

## Build provenance notes

- Workflow drove out of `/tmp/attx-172/swap-sweep-network-compliance-0245/`.
- 8th submitted network_compliance op of the session. Initial attempt at 0.246 floor (`/tmp/attx-172/swap-sweep-network-compliance-0246/`) was abandoned because that floor sat above the realised ~0.2457 band and risked non-fill.

## Operator follow-ups

- Watch pool `64f35d26…` for the scoop. Scope can't disburse ADA again until USDM-side scoops materialise (or a top-up via reorganize/contingency-disburse).
- Backfill `submitted.json` block fields when Blockfrost/koios is available.
- Drive 172-tx-log-dir PR #193 to merge.
- Consider upgrading the operator CLI to `amaru-treasury-tx 0.2.12.0` (the submit log surfaced an update-available banner).
