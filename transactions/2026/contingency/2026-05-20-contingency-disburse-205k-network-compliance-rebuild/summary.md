# contingency: disburse 205k ADA to network_compliance treasury (rebuild)

Pre-submission operational entry; the directory is named with a
slug. Will be renamed to the on-chain txid after submission.

- **CLI**: `amaru-treasury-tx 0.2.11.0`
- **Action**: disburse
- **Scope**: contingency
- **Status**: rebuilt; awaiting 4 witnesses (status as of 2026-05-20)
- **Built**: 2026-05-20 10:18 UTC (mtime of unsigned-tx.hex)
- **TTL**: slot 187878776
- **Required signers**:
  - `7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb` —
    core_development
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` —
    ops_and_use_cases
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` —
    network_compliance
  - `97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2` —
    middleware
- **Fee**: 415814 lovelace

## What

Disburse 205,000 ADA from the `contingency` treasury at
`addr1x8ndhlcfy30t38z0tql64fpg8ply93r37xrgvdagfpsz5nhxm0lsjfz7hzwy7kpl42jzswr7gtz8ruvxscm6sjrq9f8qruq0ae`
to the `network_compliance` treasury at
`addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk`,
funding network_compliance to reach its 425k USDM target (per the
wizard intent's rationale). Consumes treasury UTxO
`46c11538f39bce1e6d3bf1f9273f30b75b4eb094bbb5d121b76083eab0113d71#0`
(4,057,000 ADA) and produces a 3,852,000 ADA leftover back to the
contingency treasury plus the 205,000 ADA payment output.

## Files

- `intent.json` — wizard intent (input to `tx-build`).
- `tx.cbor` — raw unsigned transaction CBOR hex; filename invariant:
  `blake2b-256(canonical(body)) == <future-txid>`. After signing +
  submission, the directory will be renamed to that txid.
- `tx.envelope.json` — same CBOR wrapped in the `Tx ConwayEra`
  TextEnvelope used by `attach-witness` / `cardano-cli`.
- `build.log` / `wizard.log` — step traces (verbatim from
  `/tmp/attx-172/contingency-205k-rebuild/`).
- `report.json` — tx-build's deterministic report.

## Rebuild context

Previous attempt had txid
`7b91b99671bdfb45f5920d11ff74106bd26c1463a8efd924230411ef949f28d9`
(fully signed, see `/tmp/attx-172/.archived/contingency-205k/signed-tx.tx`
— operator scratch, not archived in this repo) and expired due to TTL
exhaustion before all 4 owner signatures could be collected (TTL
pitfall from the [`amaru-treasury-tx` operator skill][skill-ttl]).
This rebuild uses the same input UTxOs (`46c11538…#0` +
`59e10ca5…#2`) and same outputs; only
`validityInterval.invalidHereafter` changed.

[skill-ttl]: /home/paolino/.claude/skills/amaru-treasury-tx/SKILL.md

## Missing

- `signed-tx.{hex,tx}` — not yet collected; this is the
  pre-submission state. Once the witnesses land and `attach-witness`
  assembles a signed tx, the signed files will be added (and the
  directory renamed to its txid).
