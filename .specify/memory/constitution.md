# amaru-treasury-tx Constitution

## Core Principles

### I. Faithful port of the bash recipes

The CLI's behaviour MUST match the
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
bash entry points 1:1: `disburse`, `reorganize`, `withdraw`. The
positional argument order, the metadata file shape, and the redeemer
Plutus-data layouts are treated as the source of truth. Every
divergence requires a written justification in the spec.

### II. Pure builders, impure shell

The transaction builders MUST be pure functions over `TxBuild q e a`
(from
[`Cardano.Node.Client.TxBuild`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs)).
All effectful operations (UTxO resolution, protocol-parameter fetch,
script evaluation, time-to-slot, file I/O) live behind a small
`Backend` typeclass and are injected by `app/Main.hs`. This keeps the
core unit-testable without a node and lets us swap data sources.

### III. Pluggable data source, local-node default

The default backend is a direct N2C client (matching the trust model
of the original `cardano-cli`-based scripts). Additional backends
(Blockfrost; Ogmios+Kupo) MAY be added behind the same `Backend`
typeclass. The choice is selected at the CLI level. No backend is
allowed to leak into the pure builder modules.

### IV. Build, never sign or submit

The executable produces an unsigned Conway transaction (CBOR hex on
stdout) plus a JSON summary (txid, fee, ExUnits per script, redeemer
indexes). Signing and submission are explicitly out of scope. This
mirrors the bash recipes' `write_conway_tx` step and keeps key
material out of this tool.

### V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)

Every supported action ships with at least one golden test that
re-builds the transaction from a recorded `metadata.json` + intent
input and compares the body CBOR (excluding script-evaluation
ExUnits) against a checked-in fixture. The fixture set covers ADA
disburse, USDM disburse, reorganize, withdraw. Tests are written
before the implementation lands and must fail first.

### VI. Hackage-ready Haskell

All Haskell packages MUST pass `cabal check` with no warnings, carry
Haddock on every export, and conform to the `/haskell` skill style
(fourmolu 70-col, leading commas/arrows, explicit export lists,
StrictData, `-Werror`).

## Technology Constraints

- GHC 9.6+ (matches `cardano-node-clients`).
- `cardano-node-clients` is consumed via `source-repository-package`
  in `cabal.project`, pinned with a nix32 `--sha256:` hash. CHaP is
  enabled.
- Plutus data via `plutus-tx` (`ToData`/`FromData`).
- Conway era only (matches the deployed Amaru treasury contracts).
- Nix-first: `flake.nix` uses haskell.nix and the IOG cache; CI uses
  the self-hosted NixOS runner with `cachix-action@v15`.

## Development Workflow

- Spec-driven: every issue follows
  `/speckit.specify` → `/speckit.plan` → `/speckit.tasks` → `/speckit.implement`.
- Vertical commits, conventional-commit prefixes, linear history
  (rebase merge).
- Local CI (`just CI`) MUST pass before any push.
- PRs gated by GitHub ruleset: PR required, `Build Gate` status check
  required, admin bypass on.
- New issues are added to
  [`paolino/Planning`](https://github.com/users/paolino/projects/2)
  immediately, with category `Tooling` and ownership `Work`.

## Governance

This constitution supersedes other process documents in the repo.
Amendments are PRs that update this file and bump the version footer.
The `/speckit.plan` step gates all implementation work against these
principles; any deviation is recorded in the plan's
"Constitution Compliance" section.

**Version**: 0.1.0 | **Ratified**: 2026-05-04 | **Last Amended**: 2026-05-04
