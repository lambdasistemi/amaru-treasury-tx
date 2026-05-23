# amaru-treasury-tx Development Guidelines

Auto-generated from feature plans. Last updated: 2026-05-23

## Active Technologies
- Haskell, GHC 9.6+ (matches `cardano-node-clients`). (005-unified-tx-build)
- filesystem only — `intent.json` (wizard output), (005-unified-tx-build)
- Haskell, GHC 9.6+ (matches `cardano-node-clients`). (004-disburse-wizard)
- filesystem only — `intent.json` (wizard output), (004-disburse-wizard)
- Haskell, GHC 9.6+ (matches `cardano-node-clients`). + `cardano-node-clients` (`TxBuild q e a` DSL, `selectWallet` location), `cardano-ledger-conway` (Conway tx body for `inputsTxBodyL`/`collateralInputsTxBodyL`), `aeson` (intent.json shape). (007-aggregate-wallet-utxos)
- filesystem only — `intent.json` (wizard output, builder input). No DB or persistent state added by this feature. (007-aggregate-wallet-utxos)
- filesystem only — `report.json` (input), `report.md` (074-report-render)
- Haskell, GHC 9.6+ via the repository Nix shell. + `cardano-node-clients`, `cardano-tx-tools`, (157-flatten-devnet-cli)
- filesystem only — `bootstrap-intent.json` (input to (157-flatten-devnet-cli)
- Haskell, GHC 9.6+ (matches `cardano-node-clients`) + `cardano-node-clients` (Provider IO + N2C), `cardano-tx-tools` (`TxBuild` DSL), `cardano-ledger-conway` (Conway tx body), `plutus-tx` (`ToData`/`FromData`), `aeson` (intent.json), `contra-tracer` (informational logging) (259-swap-wizard-pure)
- filesystem only — `intent.json` (CLI output, builder input), `report.json` (builder output). No DB. (259-swap-wizard-pure)

- Haskell, GHC 9.6+ (matches `cardano-node-clients`)
- Cabal + Nix flake (haskell.nix, IOG cache)
- Hspec + golden CBOR fixtures + QuickCheck for properties
- `optparse-applicative` for CLI parsing
- `plutus-tx` for `ToData`/`FromData` (Plutus Core data values)

## Primary dependencies

- [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  for the `TxBuild q e a` DSL and the `Provider IO` record-of-functions.
- `cardano-ledger-conway` for Conway-era body, witnesses, balancing.
- `cardano-ledger-api` for `estimateMinFeeTx` and balancing helpers.

## Project Structure

```text
amaru-treasury-tx/
├── flake.nix
├── nix/
│   ├── project.nix          # haskell.nix cabalProject' (CHaP)
│   ├── checks.nix
│   ├── apps.nix
│   └── fix-libs.nix
├── cabal.project            # SRP pin: cardano-node-clients @ main
├── amaru-treasury-tx.cabal
├── README.md
├── justfile
├── lib/Amaru/Treasury/      # pure builders
│   ├── Metadata.hs
│   ├── Scope.hs
│   ├── Constants.hs
│   ├── Redeemer.hs
│   ├── Backend.hs           # alias around Cardano.Node.Client.Provider
│   ├── Backend/N2C.hs       # impure (constructs Provider IO)
│   ├── Tx/{Disburse,Reorganize,Withdraw}.hs
│   └── Summary.hs
├── app/amaru-treasury-tx/Main.hs
└── test/{unit,fixtures}
```

## Commands

```bash
just build        # cabal build all -O0
just unit         # hspec unit tests
just format       # fourmolu -i
just hlint
just ci           # build + tests + format-check + hlint
nix build .#default
nix run .#unit
nix run .#lint
```

## Code Style

- Fourmolu, 70-character column limit, leading commas/arrows.
- 4-space indentation; explicit export lists; Haddock on every export.
- `-Werror` enabled via the `common warnings` block.
- Conventional Commits.
- Linear history; rebase merge.
- See the `/haskell` and `/nix` skills for project-wide details.

## Recent Changes
- 259-swap-wizard-pure: Added Haskell, GHC 9.6+ (matches `cardano-node-clients`) + `cardano-node-clients` (Provider IO + N2C), `cardano-tx-tools` (`TxBuild` DSL), `cardano-ledger-conway` (Conway tx body), `plutus-tx` (`ToData`/`FromData`), `aeson` (intent.json), `contra-tracer` (informational logging)
- 157-flatten-devnet-cli: Added Haskell, GHC 9.6+ via the repository Nix shell. + `cardano-node-clients`, `cardano-tx-tools`,
- 074-report-render: Added Haskell, GHC 9.6+ (matches `cardano-node-clients`).

  research, data model, contracts, quickstart.

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
