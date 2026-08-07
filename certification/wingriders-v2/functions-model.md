# Command interface model

There are no new or changed product functions.

| ID | Signature-level contract |
| --- | --- |
| `CMD-REPRODUCE` | A documented command starts from the pinned repository state, performs only read-only discovery/observation and offline evaluation, and writes a fresh evidence run directory. Non-zero means the campaign did not certify. |
| `CMD-VERIFY` | A documented offline command accepts the evidence root and report path, verifies hashes/schema/control coverage/path fence/verdict shape, and exits non-zero for seeded missing, altered, or vacuous evidence. |
| `CMD-GATE` | The ticket-owner gate accepts the exact Git base and checks the allowed path, report shape, evidence hashes, and `CMD-VERIFY`. |

## Ceiling

This model is limited to 60 lines and 4 KiB.
