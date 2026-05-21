# contingency: disburse 205k ADA to network_compliance treasury

Submitted on-chain at 2026-05-21T14:57:18Z. The on-chain txid is this directory's name.

- **CLI**: `amaru-treasury-tx 0.2.11.0`
- **Action**: disburse
- **Scope**: contingency
- **Run dir**: `/tmp/attx-172/contingency-205k-rebuild`
- **Submitted**: 2026-05-21 14:57:18 UTC
- **Block**: `60509ac5a41a8919d9e00a77578f0309380d08a9002f088e85055ee6c7c883a7`
- **Slot**: 187,809,147
- **Fee**: 415,814 lovelace
- **valid_contract**: true
- **Required signers**:
  - `7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb`
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`
  - `97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2`

## What

Disbursed 205,000 ADA from contingency to the network_compliance treasury. 205,000 ADA moved to network_compliance; 3,852,000 ADA returned to contingency change.

Rationale from `intent.json`: {"description": "Contingency disburse to Network Compliance treasury", "destinationLabel": "Network Compliance treasury", "event": "disburse", "justification": "Funding Network Compliance to reach 425k USDM target", "label": "Contingency disburse"}.

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
  - `25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095`
  - `46c11538f39bce1e6d3bf1f9273f30b75b4eb094bbb5d121b76083eab0113d71`
  - `59e10ca5e03b8d243c699fc45e1e18a2a825e2a09c5efa6954aec820a4d64dfe`
  - `b25328336bbba240d5906952534e84bb8edf1a690f86a4160c38703396853c90`
  - `e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c`

## Witness collection

Witness files were collected in `/tmp/attx-172/contingency-205k-rebuild/answers/` before submission. The signed CBOR preserves the unsigned transaction body bytes; the accepted txid equals this directory name.


## Refs

- Replaces the pending slug entry from the May 20 rebuild.
