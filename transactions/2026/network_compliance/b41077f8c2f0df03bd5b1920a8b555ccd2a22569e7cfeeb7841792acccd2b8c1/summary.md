# b41077f8… — network_compliance swap #6, 40,816 ADA → ≥10,000 USDM @ floor 0.245

**Status:** submitted on-chain (block details pending indexer backfill); SundaeSwap scoop awaited. Pool `64f35d26…` was empty of operator orders at submission — the 4 orders from `9f119393…`/`77d687bc…` had all scooped earlier this session.

CLI: `amaru-treasury-tx 0.2.11.0` · cardano-tx-tools: `tx-inspect 0.2.0.0` / `tx-validate 0.2.0.0`.

## On-chain receipt

- **txid:** `b41077f8c2f0df03bd5b1920a8b555ccd2a22569e7cfeeb7841792acccd2b8c1`
- **submitted:** 2026-05-21T18:08:43Z via `amaru-treasury-tx submit`, accepted by local mainnet n2c socket.
- **inclusion confirmed at:** 2026-05-21T18:09:30Z — `tx-validate` against `signed-tx.hex` returned `ConwayMempoolFailure "All inputs are spent. Transaction has probably already been included"`. Tip at that check was slot 187,820,659 / block 13,447,721 / hash `6953ae6fca5bc5d368827e3501759163e931c748354aaab77afe43d2e9a903c3`.
- **block / block_height / slot / block_time:** pending — local n2c only, no Blockfrost/koios available this session. Recorded in `submitted.json.inclusion_evidence`.
- **fee:** 0.436937 ADA. **valid_contract:** true.

## Intent

- **Scope:** network_compliance
- **Operation:** swap ADA → USDM via SundaeSwap V3 (pool `64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef`).
- **Mode:** 2 chunks of 20,408,163,265 / 20,408,163,266 lovelace.
- **Min rate:** 0.245 USDM/ADA.
- **ADA committed to orders:** 40,816,326,531 lovelace (~40,816.327 ADA).
- **Net treasury debit:** 40,822,886,531 lovelace.
- **Treasury UTxO consumed:** `77d687bc713dd707e357fc0da992fe7eb02a6baadef0a1cbe029563b54b10a27#2` (123,354.226938 ADA — leftover from swap #5).
- **Wallet UTxO consumed:** `77d687bc…#3` (91.268013 ADA).
- **Treasury leftover output:** 82,531,340,407 lovelace returned to `network_compliance` treasury.
- **Wallet change:** 90,831,076 lovelace.
- **Expected USDM at floor:** 10,000.000001 USDM total (5,000.000001 + 5,000.000000).
- **Expected USDM at 0.2457 mid (realised band of the 4 prior scoops):** ~10,028.6 USDM.

## Signer roster

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (network_compliance owner + wallet payment key).
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` (ops_and_use_cases owner — co-signer for `Disburse` policy).

## Rationale

- **event:** disburse
- **label:** Swap ADA<->USDM
- **destinationLabel:** Network Compliance treasury
- **description:** `Swap network_compliance ADA to USDM at floor 0.245`
- **justification:** Required to pay Antithesis as vendor.

## Pre-submit validation

- `tx-inspect 0.2.0.0` with Amaru rules: clean rule-collapsed tree.
- `tx-validate 0.2.0.0 --output human` on the signed tx: `structurally clean: 0 witness-completeness failures filtered`.
- Independent fresh-context subagent recomputed the txid via blake2b-256 over the 1,501-byte body span: matched `b41077f8…` exactly. Both vkey witnesses cryptographically verify (`blake2b-224(vkey)` → declared keyhash). Value conservation closes to the lovelace (gap = `totalCollateral 655,406`, excluded from Conway's in/out balance equation). Recommendation **GO**.

## Inputs/ bundle

- 5 parent CBORs archived under `inputs/`, each verified `blake2b-256(body(tx)) == filename`:
  - `11ace24a…` — scopes deployed-at reference.
  - `25ba96f5…` — permissions deployed-at reference.
  - `810bfcbd…` — treasury script deployed-at reference.
  - `e7b395a9…` — registry deployed-at reference.
  - `77d687bc…` — parent tx (the immediately-prior swap that posted this tx's treasury input + wallet input + collateral). Lifted from this repo's own `77d687bc…/signed-tx.hex`.

## Build provenance notes

- Workflow drove out of `/tmp/attx-172/swap-10k-network-compliance-4/`.
- 6th submitted network_compliance op of the session (predecessors `a902aecd`/`d1068d4f`/`97110966`/`d5a6b515`/`037b8421` then on-main `9f119393…`/`77d687bc…` via this branch's swap #5 archive).
- Submitted to an empty operator-order queue on pool `64f35d26…` — the 4 orders from `9f119393…` and `77d687bc…` had all been scooped before this build was started.

## Operator follow-ups

- Watch pool `64f35d26…` for the scoop of these two orders. Floor 0.245; realised band on prior 4 orders averaged ~0.2457.
- Backfill `submitted.json` `block`, `block_height`, `slot`, `block_time` once Blockfrost/koios is available.
- Drive 172-tx-log-dir to merge so this archive lands on `main` (per submit-not-complete-until-merged rule).
