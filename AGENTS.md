# amaru-treasury-tx-issue70 Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-05-11

## Active Technologies
- Haskell (GHC 9.12.3 via haskell.nix; constitution supports GHC 9.6+) + `cardano-node-clients`, public sublibrary `cardano-node-clients:devnet`, `cardano-node` binary, `optparse-applicative`, `aeson`, `directory`, `time`, Hspec (080-local-devnet-smoke)
- Filesystem run directories only: socket/log transcript, timing evidence, intent JSON, unsigned CBOR, signed DevNet harness CBOR, submit/materialization proof, report JSON/Markdown (080-local-devnet-smoke/#83)

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
- 080-local-devnet-smoke: Added Haskell (GHC 9.12.3 via haskell.nix; constitution supports GHC 9.6+) + `cardano-node-clients`, public sublibrary `cardano-node-clients:devnet`, `cardano-node` binary, `optparse-applicative`, `aeson`, `directory`, `time`, Hspec

- 070-quote-derived-swap-params: Planned the `swap-quote` path,
  audit artifact, quote source abstraction, and offline proof strategy.

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
