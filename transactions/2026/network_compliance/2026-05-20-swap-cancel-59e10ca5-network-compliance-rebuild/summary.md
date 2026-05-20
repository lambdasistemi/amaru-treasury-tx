# network_compliance: cancel stale SundaeSwap V3 order (rebuild)

Pre-submission operational entry; the directory is named with a
slug. Will be renamed to the on-chain txid after submission.

- **CLI**: `amaru-treasury-tx 0.2.11.0`
- **Action**: swap-cancel
- **Scope**: network_compliance
- **Status**: rebuilt; awaiting 2 witnesses (status as of 2026-05-20)
- **Built**: 2026-05-20 10:41 UTC (mtime of unsigned-tx.hex)
- **TTL**: slot 187880196
- **Required signers**:
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` —
    network_compliance
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` —
    ops_and_use_cases
- **Fee**: 244261 lovelace
- **Pre-submit txid** (per report.json):
  `a8bab7bfe1e2ed9d3a5b40189c8de51c5974a6e05c71fc1000a6abd57500b365`
  (slot-of-submission txid; survives only if this exact body is
  submitted unchanged).

## What

Cancel a stale unfilled SundaeSwap V3 order parked at
`59e10ca5e03b8d243c699fc45e1e18a2a825e2a09c5efa6954aec820a4d64dfe#0`
and return 52,819.860941 ADA to the `network_compliance` treasury at
`addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk`.
Invoked via the `swap-cancel` subcommand directly (no wizard step,
so no `intent.json`).

## Files

- `tx.cbor` — raw unsigned transaction CBOR hex; filename invariant:
  `blake2b-256(canonical(body)) == <future-txid>`. After signing +
  submission, the directory will be renamed to that txid.
- `tx.envelope.json` — same CBOR wrapped in the `Tx ConwayEra`
  TextEnvelope used by `attach-witness` / `cardano-cli`.
- `build.log` — step trace (verbatim from
  `/tmp/attx-swap-cancel-rebuild-20260520-114136/`).
- `report.json` — `swap-cancel`'s deterministic report (orderTxIn,
  required signers, fee, returned value, pre-submit txid).

## Missing

- `intent.json` — `swap-cancel` is a direct subcommand and does not
  produce a wizard intent; `build.log` and `report.json` capture the
  full input set.
- `signed-tx.{hex,tx}` — not yet collected; this is the
  pre-submission state. Once the witnesses land and `attach-witness`
  assembles a signed tx, the signed files will be added (and the
  directory renamed to its txid).
