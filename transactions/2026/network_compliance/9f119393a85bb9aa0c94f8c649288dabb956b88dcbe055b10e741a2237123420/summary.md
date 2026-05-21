# network_compliance: two-order swap for 10k USDM

Submitted on-chain at 2026-05-21T16:05:18Z. The on-chain txid is this directory's name.

- **CLI**: `amaru-treasury-tx 0.2.11.0`
- **Action**: swap
- **Scope**: network_compliance
- **Run dir**: `/tmp/attx-172/swap-10k-network-compliance-2`
- **Submitted**: 2026-05-21 16:05:18 UTC
- **Block**: `b2dcb81b8d253db7aaf9f0750b6eefa606d3cf82907e96a3dd078c4647810047`
- **Slot**: 187,813,227
- **Fee**: 436,937 lovelace
- **valid_contract**: true
- **Required signers**:
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`

## What

Submitted a two-output SundaeSwap V3 order batch to swap network_compliance ADA toward 10,000 USDM. 40,816.326531 ADA split across two order outputs at a 0.245 USDM/ADA floor.

Rationale from `intent.json`: {"description": "Swap network_compliance ADA to USDM at floor 0.245", "destinationLabel": "Network Compliance treasury", "event": "disburse", "justification": "Required to pay Antithesis as vendor", "label": "Swap ADA<->USDM"}.

## Files

- `intent.json` — wizard intent used as `tx-build` input.
- `tx.cbor` — raw unsigned transaction CBOR hex; `blake2b-256(canonical(body)) == <dirname>`.
- `tx.envelope.json` — unsigned transaction TextEnvelope used by signing tools.
- `inputs/<parent-txid>.cbor` — parent transaction CBORs for every input, collateral input, and reference input decoded from `tx.cbor`.
- `signed-tx.hex` / `signed-tx.tx` — assembled signed transaction submitted to mainnet.
- `submit.log` — `amaru-treasury-tx submit` output showing the accepted txid.
- `submitted.json` — on-chain receipt.
- `build.log` / `wizard.log` / `report.json` — preserved builder and wizard provenance.

## Parent transactions

  - `11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54`
  - `18d57a4f104df4cc776104ce626958e2110122392e4c4c7671edc8861b48452e`
  - `25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095`
  - `810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c`
  - `e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c`

## Witness collection

Witness files were collected in `/tmp/attx-172/swap-10k-network-compliance-2/answers/` before submission. The signed CBOR preserves the unsigned transaction body bytes; the accepted txid equals this directory name.


## Refs

- This tx landed after the initial PR completeness audit.
