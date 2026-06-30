# swap-vault (on-chain)

The on-chain half of the bot-validator ([amaru-treasury-tx #396](https://github.com/lambdasistemi/amaru-treasury-tx/issues/396)):
a **non-custodial, bounded swap-vault**. Owner/treasury funds are locked under a
constraints datum; a permissioned bot may only emit SundaeSwap V3 `Swap` orders that
conform to it; the scope owner can always reclaim. A compromised bot can place
*worse-but-bounded* orders — never steal, redirect, or sell below the floor.

Treasury-agnostic; the compiled blueprint (`plutus.json`) is the only interface to
the off-chain consumer, which lives in `amaru-treasury-tx`.

**Agents: read [`AGENTS.md`](./AGENTS.md) first** — it carries the full invariant
list, the pinned SundaeSwap facts, and the build/test commands without needing the
rest of the repo.

```sh
nix run github:aiken-lang/aiken -- check   # type-check + tests
nix run github:aiken-lang/aiken -- build   # emit plutus.json
```

Status: **scaffold** — validators are `todo` stubs; Part A implements them RED-first
(A1 types → A2 Place → A3 Reclaim → A4 recall → A5 order conformance).

License: Apache-2.0.
