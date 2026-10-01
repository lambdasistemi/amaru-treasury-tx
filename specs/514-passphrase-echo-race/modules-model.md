# modules model — #514

| ID | Module | Change |
|---|---|---|
| M-1 | `Amaru.Treasury.Cli.Passphrase` | hidden read clears echo before writing the prompt and restores attributes on every exit path; may expose the hidden-read entry point to the unit suite (F-1) |
| M-2 | unit test suite | gains a pty-driven spec for M-1 |

Dependency direction unchanged. See functions-model.md.
