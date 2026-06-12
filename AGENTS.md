# Repository Agent Guide

Cross-tool entry point for AI coding agents working in this repository
(see [agents.md](https://agents.md)). Human readers should start at the
[README](README.md) and the documentation site at
<https://lambdasistemi.github.io/amaru-treasury-tx/>.

## What this repo is

`amaru-treasury-tx` is a Haskell CLI for operating the Amaru treasury on
Cardano. Typed wizards verify the upstream
`pragma-org/amaru-treasury/journal/2026/metadata.json` against the
on-chain registry NFT and build-time-pinned Plutus blobs, emit a unified
`intent.json`, and `tx-build` turns that intent into unsigned Conway
CBOR — re-evaluating every redeemer against a live `ChainContext` before
writing bytes. The same binary creates age-encrypted vault-backed
witnesses, merges them, and submits via a local node socket. A separate
`amaru-treasury-tx-api` executable serves a read-only HTTP API + browser
SPA backed by an embedded chain-sync indexer. It is a Haskell port of
the bash recipes in the upstream journal, built on the
[`cardano-node-clients` `TxBuild` DSL](https://github.com/lambdasistemi/cardano-node-clients).

## How to work here

Everything runs inside the Nix shell.

```bash
nix develop                 # GHC 9.12.3 via haskell.nix + cabal, just, fourmolu, hlint
just build                  # cabal build all -O0
just unit                   # hspec unit tests   (just unit "<match>" to focus)
just golden                 # golden CBOR/report fixtures
just format                 # fourmolu -i + cabal-fmt -i
just hlint
just schema-check           # diff committed JSON Schemas against the emitters
just smoke                  # offline CLI-surface smoke checks
just ci                     # build + schema-check + unit + golden + format-check + hlint + smoke + release-check
nix flake check             # full flake checks (what CI runs)
```

Opt-in, node-backed (not part of `just ci`):

```bash
just devnet-smoke node                                   # library devnet node smoke
just devnet-cli-smoke --phase full --timeout-seconds 900 # shipped-CLI devnet proof
just devnet-api-smoke                                    # #242 API live-boundary smoke
```

### Code style

- Fourmolu, **70-character** column limit, 4-space indentation, leading
  commas/arrows; `cabal-fmt` for the `.cabal` file.
- `GHC2021`, explicit export lists, Haddock on every export.
- `-Werror` via the `common warnings` block.
- Conventional Commits; linear history (rebase merge).
- See the `/haskell` and `/nix` skills for project-wide conventions.

### Primary dependencies

- [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  — the `TxBuild q e a` DSL and the `Provider IO` record-of-functions.
- `cardano-ledger-conway` — Conway-era body, witnesses, balancing.
- `cardano-ledger-api` — `estimateMinFeeTx` and balancing helpers.
- `cardano-tx-tools`, `plutus-tx` (`ToData`/`FromData`),
  `optparse-applicative`, `aeson`, `servant-server` (API),
  `contra-tracer` (typed step traces).

## Repository map

| Path | Purpose |
| :--- | :------ |
| `lib/Amaru/Treasury/` | Library: pure builders, wizards, intent schema, CLI parsers, API, indexer, RDF history. |
| `lib/Amaru/Treasury/Cli/` | `optparse-applicative` subcommand parsers + runners (the CLI surface). |
| `lib/Amaru/Treasury/Build/` | `tx-build` action runners (swap, disburse, withdraw, reorganize, …). |
| `lib/Amaru/Treasury/Tx/` | Pure `TxBuild q e ()` programs per action. |
| `lib/Amaru/Treasury/Api/` | `amaru-treasury-tx-api` HTTP server, config, lag guard, indexer wiring. |
| `app/` | Nine executables (see `amaru-treasury-tx.cabal`); `app/amaru-treasury-tx/Main.hs` is the main CLI entry point. |
| `frontend/` | PureScript + Halogen SPA (spago), bundled into the API container. |
| `docs/` | MkDocs site sources (`mkdocs.yml` nav). |
| `skills/` | Vendor-neutral Agent Skills (see below). |
| `test/` | `unit`, `golden`, `red`, `devnet` suites + `test/fixtures/`. |
| `transactions/` | In-repo archive of submitted mainnet treasury transactions per scope. |
| `scripts/` | Smoke harness (`scripts/smoke/`), release helpers (`scripts/release/`). |
| `nix/`, `flake.nix`, `justfile` | Build/release tooling — do not edit for docs work. |

## Skills

Activatable, vendor-neutral [Agent Skills](https://agentskills.io/home)
live under `skills/`. Any compatible agent (Claude Code, OpenAI Codex,
Cursor, GitHub Copilot, Gemini CLI, OpenCode, Goose, …) discovers them
by name/description and loads the body when triggered.

- [`skills/amaru-treasury-tx-guide/`](skills/amaru-treasury-tx-guide/) —
  orientation for working *on* this codebase: repository map, build /
  test / run, where each feature lives, and where the answers to common
  user questions live. Load this first when navigating or modifying the
  repo.
- [`skills/amaru-treasury-tx-operator/`](skills/amaru-treasury-tx-operator/) —
  end-to-end operator workflow for driving the CLI *in production*:
  build → witness → assemble → inspect → validate → submit → archive
  into `transactions/`. The first time it runs on a host it conducts a
  one-time interview and caches the operator's paths/identities to
  `~/.config/amaru-treasury-tx/operator.json`. Triggers:
  `amaru-treasury-tx`, any `*-wizard` subcommand, `attach-witness`,
  `treasury-inspect`, signing/archiving an Amaru treasury tx.

## First-run setup for new operators

If you're an agent loaded into this repo for the first time on a new
host and the task involves *running* the CLI against a node, check
whether `~/.config/amaru-treasury-tx/operator.json` exists before doing
anything else. If it doesn't, load
`skills/amaru-treasury-tx-operator/SKILL.md` and walk through its
first-run interview. Subsequent sessions read the file silently — no
re-asking.
