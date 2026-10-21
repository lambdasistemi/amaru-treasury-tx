# Survey data model

| ID | Fields and invariants |
| --- | --- |
| `DATA-OBSERVATION` | Invariant ID, UTC time, observed slot or explicit off-chain clock, source kind, authoritative identity, exact command or request digest, real exit code/status, raw path, SHA-256, and freshness class. |
| `DATA-VENUE` | Venue/version, classification (`own-liquidity`, `router`, `no-route`), exact input/output asset IDs, pool/order identity and outref if applicable, reserves/depth, fee components, node verification capture, positive control, and limitations. |
| `DATA-QUOTE` | Venue/route, snapshot identity, input base units, output base units, clip size/output, fixed and proportional overheads, effective ADA/USDM, rounding rule, underlying liquidity IDs, executable/not-executable status, and target delta. |
| `DATA-SPLIT` | Snapshot identity, disjoint underlying liquidity allocations and outputs, aggregate input/output/overheads, target delta, router cross-check delta, and proof that no liquidity ID repeats. |
| `DATA-HISTORY` | Window start/end slots and UTC, query coverage, examined request and batch counts, beneficiary credential class, request/batch linkage, script-beneficiary batched count, and positive-control identities. |
| `DATA-VERDICT` | Q1 allowed verdict, Q2 allowed verdict, best single/split identities and target deltas, refresh marker, limitations, and one recommendation. |

Raw captures are immutable after hashing. A refreshed quote creates a new
capture and observation row; it does not overwrite a hash-bound observation.

## Ceiling

This model is limited to 70 lines and 5 KiB.
