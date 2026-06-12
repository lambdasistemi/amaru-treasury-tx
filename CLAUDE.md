# CLAUDE.md

This project's agent guidance is maintained in **[AGENTS.md](AGENTS.md)**
— the portable, cross-tool entry point. Claude Code reads this file
automatically; start from AGENTS.md for:

- what this repo is,
- how to work here (`nix develop`, `just build` / `unit` / `golden` /
  `ci`, `nix flake check`),
- code style (fourmolu 70-column, `GHC2021`, `-Werror`),
- the repository map and primary dependencies,
- the Agent Skills under `skills/` (`amaru-treasury-tx-guide`,
  `amaru-treasury-tx-operator`).

Keep durable guidance in AGENTS.md, not here, so every agent (not just
Claude Code) sees it.
