# Command interface model

There are no new or changed product functions.

| ID | Signature-level contract |
| --- | --- |
| `CMD-OBSERVE` | A documented read-only command records node freshness, venue identities/state, executable quote surfaces, or WingRiders history into a fresh evidence run. Non-zero is recorded and cannot certify a claim. |
| `CMD-CALCULATE` | A documented offline command accepts hash-bound structured venue observations plus the fixed input/target and emits deterministic integer single/split quote results with unique underlying-liquidity IDs. |
| `CMD-VERIFY` | A documented offline command accepts the survey root, validates manifests/schema/control coverage/asset identity/arithmetic/no-double-count/freshness/report shape, and exits non-zero for seeded altered, missing, or vacuous evidence. |
| `CMD-GATE` | The ticket-owner gate accepts the exact Git base and checks the tracked path fence, required artifacts, task state policy, evidence hashes, fixed constants, venue/Danogo coverage, and `CMD-VERIFY`. |

## Ceiling

This model is limited to 55 lines and 4 KiB.
