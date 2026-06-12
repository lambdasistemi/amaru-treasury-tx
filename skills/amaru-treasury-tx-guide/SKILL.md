---
name: amaru-treasury-tx-guide
description: Orientation for working ON the amaru-treasury-tx codebase (not running it in production — that is amaru-treasury-tx-operator). Load this when navigating, understanding, or modifying the repo: "where is the swap/disburse/withdraw/reorganize builder", "how does tx-build dispatch on the intent action", "where are the optparse-applicative subcommands defined", "how does the amaru-treasury-tx-api indexer / lag guard work", "where is the intent.json schema generated", "how do I add a CLI flag or a wizard", "where do golden fixtures live", "what does just ci / just smoke / nix flake check run", build/test/format failures, GHC 9.12.3 + haskell.nix, fourmolu 70-column, and answering user questions about what this repo does. Key paths: lib/Amaru/Treasury/Cli/, lib/Amaru/Treasury/Build/, lib/Amaru/Treasury/Tx/, lib/Amaru/Treasury/Api/, app/, test/golden/, test/fixtures/, docs/, justfile, flake.nix.
---

# amaru-treasury-tx codebase guide

Orientation for agents working *on* this repository. To *run* the CLI
against a node (build → witness → assemble → submit → archive), load
`amaru-treasury-tx-operator` instead. For the human-facing tour, read
the [README](../../README.md) and the docs site.

## Repository map

| Path | What lives here |
| :--- | :--- |
| `app/amaru-treasury-tx/Main.hs` | Main CLI entry point: UTF-8 setup, update check, parse, dispatch. |
| `app/*` | The other eight executables (api, schema emitters, probes, devnet host, capture-swap-context). |
| `lib/Amaru/Treasury/Cli.hs` | Top-level subcommand tree (`progDesc` strings, `--version`, global options). |
| `lib/Amaru/Treasury/Cli/*.hs` | One module per subcommand: parsers + runners (`TxBuild.hs`, `SwapWizard.hs`, `DisburseWizard.hs`, `WithdrawWizard.hs`, `ReorganizeWizard.hs`, `SwapCancel.hs`, `SwapQuote.hs`, `Vault.hs`, `Witness.hs`, `AttachWitness.hs`, `Submit.hs`, `TreasuryInspect.hs`, `History.hs`, `Serve.hs`, …). |
| `lib/Amaru/Treasury/Build/*.hs` | `tx-build` action runners + the dispatcher; `Build/Reorganize/Batch.hs` is the auto-batcher. |
| `lib/Amaru/Treasury/Tx/*.hs` | Pure `TxBuild q e ()` programs per action. |
| `lib/Amaru/Treasury/IntentJSON*.hs` | Unified `intent.json` schema, parser, encoder; `IntentJSON/Schema.hs` emits the JSON Schema. |
| `lib/Amaru/Treasury/Api/*.hs` | `amaru-treasury-tx-api`: `Server.hs` (Servant `/v1/*` + SPA), `Config.hs` (flags/env), `LagGuard` (HTTP 503 when the indexer drifts). |
| `lib/Amaru/Treasury/Indexer/`, `History/` | RocksDB chain-sync indexer; RDF/SPARQL/SHACL history lattice. |
| `lib/Amaru/Treasury/Registry/*.hs` | Re-derive script hashes from pinned Plutus blobs; verify metadata against chain anchors. |
| `lib/Amaru/Treasury/ChainContext.hs` | Live vs frozen `ChainContext` envelope (the chain snapshot tx-build evaluates against). |
| `test/unit/`, `test/golden/`, `test/red/`, `test/devnet/` | Hspec suites; `test/fixtures/` holds frozen CBOR/report goldens. |
| `docs/`, `mkdocs.yml` | Documentation site sources and nav. |
| `assets/plutus/`, `assets/blueprints/` | Compiled validators (CBOR) + CIP-57 blueprints. |
| `justfile`, `flake.nix`, `nix/` | Build, test, lint, release tooling. |

## Build, test, run

Always inside `nix develop` (GHC 9.12.3 via haskell.nix).

```bash
just build          # cabal build all -O0
just unit "<match>" # focus one hspec example; omit the arg for all
just golden         # byte-identity CBOR + report goldens
just format         # fourmolu -i + cabal-fmt -i   (70-col, 4-space)
just hlint
just schema-check   # committed JSON Schemas vs the schema emitters
just smoke          # offline CLI-surface smoke (scripts/smoke/*)
just ci             # the full local gate
nix flake check     # what CI runs
```

`UPDATE_GOLDENS=1 cabal test golden-tests --test-option=--match --test-option="<name>"`
regenerates a golden after an intentional builder change. The
`red-tests` suite is expected to fail until its green-step lands and is
**not** in `just ci`.

## Navigating the code

- **Add or change a CLI flag** → the subcommand's module under
  `lib/Amaru/Treasury/Cli/`, then its `progDesc`/parser wiring in
  `lib/Amaru/Treasury/Cli.hs`. Keep `scripts/smoke/*` help-text
  assertions in sync (`just smoke`).
- **Change how a transaction is built** → the action runner in
  `lib/Amaru/Treasury/Build/` and the pure program in
  `lib/Amaru/Treasury/Tx/`. `tx-build` dispatches on the intent's
  `action` + `network` fields — there is no per-command network flag for
  the build path.
- **Change the intent shape** → `lib/Amaru/Treasury/IntentJSON*`, then
  `just update-schema` and commit `docs/assets/intent-schema.json`
  (CI diffs it via `just schema-check`).
- **Touch the API** → `lib/Amaru/Treasury/Api/`. The container fails
  closed (HTTP 503) when the embedded indexer lags past
  `--indexer-lag-threshold-slots` (default 60).
- **A value-affecting step** is routed through a typed `Tracer`
  (`WizardEvent`, `BuildEvent`) — see the [trust model](../../docs/trust-model.md).

## Using the artifact

The shipped surface is documented per command in `docs/` and summarised
in the [README Usage table](../../README.md). Headline pipeline:

```bash
amaru-treasury-tx <action>-wizard … --out intent.json
amaru-treasury-tx tx-build --intent intent.json --out tx.cbor.hex --report report.json
amaru-treasury-tx witness --tx tx.cbor.hex --vault vault.age --identity <label> --out w.hex
amaru-treasury-tx attach-witness --tx tx.cbor.hex --witness "$(cat w.hex)" --out signed.hex
amaru-treasury-tx submit --tx signed.hex
```

Read-only: `treasury-inspect`, `history`, `tx-detail`. Service:
`serve` / `amaru-treasury-tx-api`. DevNet bootstrap wizards
(`registry-init-wizard`, `stake-reward-init-wizard`,
`governance-withdrawal-init-wizard`) are devnet-only.

## Answering questions

| User asks… | Answer lives in |
| :--- | :--- |
| "What does this tool do?" | [README](../../README.md) → *What is this*; `docs/index.md`. |
| "How do I run a swap / disburse / withdraw / reorganize?" | `docs/swap.md`, `docs/disburse.md`, `docs/withdraw.md`, `docs/reorganize.md`. |
| "What are the exact flags for command X?" | `amaru-treasury-tx X --help`; parser source in `lib/Amaru/Treasury/Cli/X*.hs`. |
| "What does the wizard verify vs. what must I assert?" | `docs/trust-model.md`. |
| "How is the swap byte-parity proven?" | `docs/parity.md`; `test/fixtures/swap/`, `test/golden/SwapGoldenSpec.hs`. |
| "How does the API/dashboard stay correct under chain lag?" | `docs/api-container-indexer.md`; `lib/Amaru/Treasury/Api/`. |
| "How do I bootstrap a fresh DevNet?" | `docs/devnet-bootstrap.md`; `docs/local-devnet-smoke.md`. |
| "What scopes exist?" | `lib/Amaru/Treasury/Scope.hs` — `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`, `contingency`. |
| "How do I operate the live treasury / sign / archive?" | Load `amaru-treasury-tx-operator`. |
