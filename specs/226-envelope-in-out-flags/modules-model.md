# modules model — #226

| ID | Module | Change |
|---|---|---|
| M1 | `Amaru.Treasury.Cli` | `Cmd` envelope constructors carry an IO-path options value; parser exposes `--in`/`--out` (D1). |
| M2 | `Amaru.Treasury.Cli.Envelope` | owns the IO-path options type and the runners resolving stdin/stdout fallback (F1, F2). Pure filters unchanged. |
| M3 | `app/amaru-treasury-tx/Main.hs` | dispatch passes options through; no logic. |

Dependency direction unchanged: `Cli` → `Cli.Envelope` → `Tx.Envelope`.
