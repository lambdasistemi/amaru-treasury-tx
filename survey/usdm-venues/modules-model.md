# Modules model

| ID | Responsibility | Dependency direction |
| --- | --- | --- |
| `MOD-OBSERVE` | Throwaway read-only venue, node, quote, and history instruments. | May consume public discovery services, venue quote surfaces, the local node, and frozen #491 evidence. It must not become product code. |
| `MOD-CAPTURES` | Immutable raw command output, exit receipts, observation rows, hashes, and controls. | Produced by observation instruments; consumed by the verifier, calculations, report, and auditor. |
| `MOD-CALCULATE` | Reproducible integer quote and disjoint-liquidity routing results. | Consumes only captured venue state and fee models; emits structured results, never new observations. |
| `MOD-VERIFY` | Offline integrity, schema, coverage, control, arithmetic, freshness, and path-fence checks. | Consumes captures, structured results, and report; is independent of report prose. |
| `MOD-REPORT` | Dated answers to Q1 and Q2 plus recommendation. | Derived from verified captures and results; never used as their oracle. |

No existing product module changes responsibility.

## Ceiling

This model is limited to 55 lines and 4 KiB.
