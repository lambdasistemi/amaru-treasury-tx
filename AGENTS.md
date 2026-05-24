# amaru-treasury-tx-issue70 Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-05-24

## Active Technologies
- Haskell (GHC 9.12.3 via haskell.nix; constitution supports GHC 9.6+) + `cardano-node-clients`, public sublibrary `cardano-node-clients:devnet`, `cardano-node` binary, `optparse-applicative`, `aeson`, `directory`, `time`, Hspec (080-local-devnet-smoke)
- Filesystem run directories only: socket/log transcript, timing evidence, intent JSON, unsigned CBOR, signed DevNet harness CBOR, submit/materialization proof, report JSON/Markdown (080-local-devnet-smoke/#83)
- Haskell, GHC 9.6+ via the repository Nix shell. + `cardano-node-clients`, `cardano-tx-tools`, (157-flatten-devnet-cli)
- filesystem only — `bootstrap-intent.json` (input to (157-flatten-devnet-cli)
- Haskell, GHC 9.6+ via the repository Nix shell + `cardano-tx-tools` via `cabal.project` (191-bump-tx-tools)
- Haskell, GHC 9.6+ (matches `cardano-node-clients`); PureScript / Halogen for the frontend tabs. + `cardano-node-clients` (`TxBuild` DSL, `Backend`/`Provider IO`), `cardano-ledger-conway` (Conway tx body, balancing), `cardano-tx-tools` (`Cardano.Tx.Build`, `setMetadata`), `servant-server` (HTTP endpoint), `aeson` (response shape), `browser-json-tree` flake input (frontend rendering of the Report tab). (270-build-swap-typed)
- Filesystem only — `intent.json`, `tx.cbor`, `report.json` (CLI output); HTTP response carries the same payloads in-band. No database, no on-disk state for the API. (270-build-swap-typed)

- Haskell, GHC 9.6+ (070-quote-derived-swap-params)
- Cabal single-package CLI with haskell.nix flake checks
- Existing `optparse-applicative`, `aeson`, `aeson-pretty`, `time`,
  `text`, and Cardano ledger/client dependencies

## Project Structure

```text
app/amaru-treasury-tx/
lib/Amaru/Treasury/
test/unit/
test/golden/
test/fixtures/
docs/
specs/
```

## Commands

- `just ci`
- `just cabal-check`
- `just schema-check`
- `nix flake check`

## Code Style

- Haskell modules use explicit export lists, Haddock on exports,
  fourmolu formatting, and warnings clean enough for `-Werror`.
- Transaction builders stay pure; IO belongs in CLI/backend seams.
- New quote-derived swap logic should keep arithmetic pure and quote
  fetching behind an injectable source.

## Recent Changes
- 270-build-swap-typed: Added Haskell, GHC 9.6+ (matches `cardano-node-clients`); PureScript / Halogen for the frontend tabs. + `cardano-node-clients` (`TxBuild` DSL, `Backend`/`Provider IO`), `cardano-ledger-conway` (Conway tx body, balancing), `cardano-tx-tools` (`Cardano.Tx.Build`, `setMetadata`), `servant-server` (HTTP endpoint), `aeson` (response shape), `browser-json-tree` flake input (frontend rendering of the Report tab).
- 191-bump-tx-tools: Added Haskell, GHC 9.6+ via the repository Nix shell + `cardano-tx-tools` via `cabal.project`
- 157-flatten-devnet-cli: Added Haskell, GHC 9.6+ via the repository Nix shell. + `cardano-node-clients`, `cardano-tx-tools`,

  audit artifact, quote source abstraction, and offline proof strategy.

<!-- MANUAL ADDITIONS START -->

## Skills

Activatable, vendor-neutral [Agent Skills](https://agentskills.io/home)
live under `skills/`. Any compatible agent (Claude Code, OpenAI
Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Goose, …) will
discover them by name/description and load the body when triggered.

- [`skills/amaru-treasury-tx-operator/`](skills/amaru-treasury-tx-operator/) —
  end-to-end operator workflow: build → witness → assemble → inspect
  → validate → submit → archive into `transactions/`. **The first
  time this skill runs on a host it conducts a one-time interview
  and writes the operator's answers to
  `~/.config/amaru-treasury-tx/operator.json`**, then reuses them
  for every subsequent run. Triggers: `amaru-treasury-tx`, any
  `*-wizard` subcommand, `attach-witness`, `treasury-inspect`,
  signing for the Amaru treasury, archiving a submitted tx.

## First-run setup for new operators

If you're an LLM agent loaded into this repo for the first time on
a new host, before doing anything else check whether
`~/.config/amaru-treasury-tx/operator.json` exists. If it doesn't,
load `skills/amaru-treasury-tx-operator/SKILL.md` and walk through
its first-run interview. Subsequent sessions read the file
silently — no re-asking.
<!-- MANUAL ADDITIONS END -->
