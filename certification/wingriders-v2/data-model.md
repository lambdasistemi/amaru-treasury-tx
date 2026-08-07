# Evidence data model

| ID | Fields and invariants |
| --- | --- |
| `DATA-OBSERVATION` | CQ/invariant ID, UTC time, observed slot, source kind, pinned commit or outref, command, real exit code, raw-log path, and SHA-256. |
| `DATA-CONTROL` | Target observation, control kind (`positive`, `red`, or `green`), independently constructed input identity, expected result, actual exit/result, and capture hash. |
| `DATA-DEPLOYMENT` | Request script hash/address/language; pool NFT/type/assets/scales/reserves/outref; fees/oil; independent chain and source provenance. |
| `DATA-VERDICT` | Exactly one allowed verdict, CQ1-CQ4 results, certification-failure boundary if any, separate custody findings, registry deltas, enforcement `NONE`. |

Raw captures are immutable after hashing. If re-run, create a new capture and
update the manifest; never rewrite evidence in place without changing its
hash-bound record.

## Ceiling

This model is limited to 70 lines and 4 KiB.
