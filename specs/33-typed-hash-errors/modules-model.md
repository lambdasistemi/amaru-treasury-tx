# modules model — #33

| ID | Module | Change |
|---|---|---|
| M-1 | `Amaru.Treasury.IntentJSON.Common` | sole owner of byte-string → hash conversion (F-1); partial `mkHash28`/`mkHash32` removed |
| M-2 | `Amaru.Treasury.Tx.DisburseIntentJSON` | local hash helpers deleted; depends on M-1 for F-1 |
| M-3 | `Amaru.Treasury.IntentJSON`, `Tx.DisburseWizard`, `Tx.ReorganizeWizard` | call sites consume F-1 through their existing error channel |
| M-4 | `Amaru.Treasury.Devnet.GovernanceWithdrawalInit` | constant hash helper total (or explicitly harness-named) |

Dependency direction unchanged: parsers → `IntentJSON.Common`.
