# modules model — #234

| ID | Module | Change |
|---|---|---|
| M1 | `Amaru.Treasury.Cli` | `vaultCmdP` gains `relabel`; `Cmd` gains its constructor (D1). |
| M2 | `Amaru.Treasury.Cli.Vault` | owns relabel options/parser and runner (F1, F2): passphrase read, decrypt, relabel, re-encrypt, atomic write; shares the existing atomic writer. |
| M3 | `Amaru.Treasury.Vault.Witness` | owns the pure payload relabel over the v1 document (F3); vault-schema errors stay here (D2). |
| M4 | `Amaru.Treasury.Vault.Age` | exposes the input's scrypt work factor (F4); stays the only `age` importer. |
| M5 | `app/amaru-treasury-tx/Main.hs` | dispatch only. |

Dependency direction unchanged: `Cli` → `Cli.Vault` →
`Vault.Witness`, `Vault.Age`, `Cli.Passphrase`.
