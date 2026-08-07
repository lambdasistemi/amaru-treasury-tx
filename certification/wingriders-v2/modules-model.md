# Modules model

| ID | Responsibility | Dependency direction |
| --- | --- | --- |
| `MOD-HARNESS` | Throwaway reproducible evidence tooling and offline evaluator entrypoints. | May read repository-vendored artifacts, pinned upstream checkouts, read-only index responses, and the local node. It must not become product code or a product dependency. |
| `MOD-CAPTURES` | Immutable raw command output, receipts, hashes, and positive/red/green controls. | Produced by the harness; consumed by the verifier, report, and auditor. |
| `MOD-REPORT` | Dated CQ1-CQ4 findings, custody separation, verdict, and registry deltas. | Derived from captures, never used as their oracle. |

No existing product module changes responsibility.

## Ceiling

This model is limited to 60 lines and 4 KiB.
