# 3ecffded… — network_compliance swap #7, 40,816 ADA → ≥10,000 USDM @ floor 0.245

**Status:** submitted on-chain (block details pending indexer backfill); SundaeSwap scoop awaited. Scope leftover after this swap drops to ~41.7k ADA — next sizeable swap is expected to sweep the remainder.

CLI: `amaru-treasury-tx 0.2.11.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `3ecffded917bb6aac602ae47ceb107b4c16c791e0956001565a920cfb1c03c6f`
- **submitted:** 2026-05-21T18:42:31Z via `amaru-treasury-tx submit`, accepted by local mainnet n2c socket.
- **inclusion confirmed at:** 2026-05-21T18:43:30Z — `tx-validate` mempool short-circuit. Tip: slot 187,822,676 / block 13,447,835 / hash `15131596091d0f44df94d914bf3ab50d0fcd0852c540b08e77bb7dfcfc7684b3`.
- **block / block_height / slot / block_time:** pending indexer backfill (recorded in `submitted.json.inclusion_evidence`).
- **fee:** 0.436937 ADA. **valid_contract:** true.

## Intent

- **Scope:** network_compliance
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26…`).
- **Mode:** 2 chunks of 20,408,163,265 / 20,408,163,266 lovelace.
- **Min rate:** 0.245 USDM/ADA.
- **ADA committed to orders:** 40,816,326,531 lovelace.
- **Net treasury debit:** 40,822,886,531 lovelace.
- **Treasury UTxO consumed:** `b41077f8…#2` (82,531.340407 ADA — leftover from swap #6).
- **Wallet UTxO consumed:** `b41077f8…#3` (90.831076 ADA).
- **Treasury leftover output:** 41,708,453,876 lovelace returned to network_compliance treasury.
- **Wallet change:** 90,394,139 lovelace.
- **Expected USDM at floor:** 10,000.000001 USDM. At 0.2457 realised band: ~10,028.6 USDM.

## Signer roster

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key).
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner — co-signer for Disburse policy).

## Rationale

- event: disburse · label: Swap ADA<->USDM · destinationLabel: Network Compliance treasury
- description: Swap network_compliance ADA to USDM at floor 0.245
- justification: Required to pay Antithesis as vendor

## Pre-submit validation

- `tx-inspect 0.2.0.0` with Amaru rules: clean rule-collapsed tree, no surprises.
- `tx-validate 0.2.0.0 --output human` on signed tx: `structurally clean: 0 witness-completeness failures filtered`.
- Independent fresh-context subagent recomputed txid via blake2b-256 over 1,501-byte body span: matched `3ecffded…` exactly. Value conservation closes to the lovelace. Recommendation **GO** with depletion caveat.

## Inputs/ bundle

- 5 parent CBORs archived under `inputs/`, each verified `blake2b-256(body(tx)) == filename`:
  - `11ace24a…` — scopes deployed-at reference.
  - `25ba96f5…` — permissions deployed-at reference.
  - `810bfcbd…` — treasury script deployed-at reference.
  - `e7b395a9…` — registry deployed-at reference.
  - `b41077f8…` — parent tx (swap #6) lifted from this repo's own archive.

## Build provenance notes

- Workflow drove out of `/tmp/attx-172/swap-10k-network-compliance-5/`.
- 7th submitted network_compliance op of the session.

## Operator follow-ups

- Watch pool `64f35d26…` for the scoop of these two orders.
- Backfill `submitted.json` block fields when Blockfrost/koios is available.
- Plan a follow-up sweep-style swap (`--all-ada`) of the ~41.7k ADA leftover; this entry's `3ecffded…#2` will be the input.
- Drive 172-tx-log-dir PR #193 to merge.
