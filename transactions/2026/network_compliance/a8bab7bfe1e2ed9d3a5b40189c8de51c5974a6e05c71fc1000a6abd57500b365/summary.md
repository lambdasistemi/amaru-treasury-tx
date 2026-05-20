# network_compliance: swap-cancel (returns 52,819.86 ADA from stale SundaeSwap V3 order)

Submitted on-chain at 2026-05-20T13:28:25Z. The on-chain txid is
this directory's name.

- **CLI**: `amaru-treasury-tx 0.2.11.0`
- **Action**: swap-cancel
- **Scope**: network_compliance
- **Built**: 2026-05-20 10:41 UTC  (mtime of unsigned-tx.hex)
- **Submitted**: 2026-05-20 13:28:25 UTC
- **Block**: `1674cdecc33e33a69e85a6446fd6edb493365306bae76e6fd1db5538a613dd0b`
- **Slot**: 187,717,414
- **Fee**: 244,261 lovelace
- **valid_contract**: true
- **Required signers**:
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` — network_compliance
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` — ops_and_use_cases

## What

Cancelled the stale SundaeSwap V3 order at
`59e10ca5e03b8d243c699fc45e1e18a2a825e2a09c5efa6954aec820a4d64dfe#0`
(the last swap-out tx in the historical bootstrap sequence — see
that entry in this scope for context). 52,819.860941 ADA returned
to the network_compliance treasury at
`addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk`.

Combined with the in-flight 205,000 ADA contingency disburse,
this brings ~257,820 ADA available at network_compliance for the
next swap.

## Files

- `tx.cbor` — raw unsigned transaction CBOR hex; `blake2b-256(canonical(body)) == <dirname>`.
- `inputs/<parent-txid>.cbor` — every parent tx whose output(s) this
  tx consumes (incl. reference inputs), as raw CBOR. Same naming
  invariant. Together with `tx.cbor`, these CBORs let an auditor
  reconstruct the consumed UTxOs from cryptographically anchored
  bytes alone.
- `signed-tx.hex` / `signed-tx.tx` — assembled signed transaction
  (operator witness bundle attached). Includes the 2 vkey witnesses
  collected via the Q/A flow during signing.
- `submit.log` — operator's submission output (verbatim from
  `amaru-treasury-tx submit`).
- `submitted.json` — on-chain receipt:
  `{ txid, block, slot, block_time, timestamp, submitter, fee_lovelace, valid_contract }`.
- `build.log` / `report.json` — `tx-build`'s step trace and
  deterministic report; preserved verbatim.

## Witness collection

The two required signers' witnesses were collected via Q/A files
under the operator's working dir
`/tmp/attx-swap-cancel-rebuild-20260520-114136/` between build
(10:41 UTC) and submission (13:28 UTC). Both witnesses were
verified (`blake2b-224(vkey) == required-signer hash`) before
assembly. The signed CBOR's body bytes were preserved verbatim
from the unsigned CBOR — the recomputed txid from the signed tx
equals the directory name.

## Rebuild context

This is a REBUILD of an earlier attempt that expired due to TTL
before both owners signed. The earlier attempt's unsigned tx
bytes were discarded; only this rebuild is on-chain. Operators
confirmed beforehand that the cancelled order
(`59e10ca5…#0`) was still unfilled at the rebuild time and that
cancelling it would not race with a partial scoop.

## Refs

- The cancelled order's submission tx is the last entry under this
  scope: `transactions/2026/network_compliance/59e10ca5e03b8d243c699fc45e1e18a2a825e2a09c5efa6954aec820a4d64dfe/`.
- Pending companion: the contingency 205k disburse rebuild at
  `transactions/2026/contingency/2026-05-20-contingency-disburse-205k-network-compliance-rebuild/`.
