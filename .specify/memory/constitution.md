# amaru-treasury-tx Constitution

## Core Principles

### I. Faithful port of the bash recipes

The CLI's behaviour MUST match the
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
bash entry points 1:1: `disburse`, `reorganize`, `withdraw`. The
positional argument order, the metadata file shape, and the redeemer
Plutus-data layouts are treated as the source of truth. Every
divergence requires a written justification in the spec.

**Tie-break (load-bearing).** When the bash recipes — or the on-chain
behaviour they have already produced and our golden CBOR fixtures
capture — conflict with any external specification (notably the
[SundaeSwap TOM metadata spec](https://github.com/SundaeSwap-finance/treasury-contracts/blob/ad4316d0d36cdef780f85fc2ec8b307e645ddc2a/offchain/src/metadata/spec.md)
referenced by Principle VII), the bash recipes win. We do not break
goldens to chase a spec. Closing the gap is a separate, deliberate
amendment to this constitution, not an opportunistic cleanup.

### II. Pure builders, impure shell

The transaction builders MUST be pure functions over the `TxBuild`
monad from
[`Cardano.Tx.Build`](https://github.com/lambdasistemi/cardano-tx-tools/blob/main/lib/Cardano/Tx/Build.hs)
(in [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)).
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

### VII. Label-1694 metadata: bash parity over spec body-shape

Principle I (faithful port of the bash recipes) governs the rationale
metadatum body shape. The bash recipes are schema-agnostic — they
pass through whatever the operator put in `RATIONALE_JSON` — so what
counts as "the bash shape" is the shape captured in this repo's
golden CBOR fixtures (paragraphs as arrays of strings, `@context` as
a 3-element URL array, `justification` as a body field). That shape
is what we emit and what we golden-test against.

Two narrow points of conformance with the SundaeSwap TOM spec are
non-negotiable, because they affect indexer correctness without
breaking the body-shape goldens:

1. **The pinned spec commit.** The URL we emit in `@context` MUST
   identify the
   [SundaeSwap-finance/treasury-contracts metadata spec](https://github.com/SundaeSwap-finance/treasury-contracts/blob/ad4316d0d36cdef780f85fc2ec8b307e645ddc2a/offchain/src/metadata/spec.md)
   at commit `ad4316d0d36cdef780f85fc2ec8b307e645ddc2a`
   (concatenation of the three URL segments emitted by
   [`lib/Amaru/Treasury/AuxData.hs`](../../lib/Amaru/Treasury/AuxData.hs)).
   Bumping the pinned commit is a deliberate amendment: update the
   SHA in `AuxData.hs`, re-verify the `event` enum below, and bump
   this constitution's version footer.

2. **The `event` enum.** The `event` value MUST come from the spec's
   closed list: `publish`, `initialize`, `reorganize`, `fund`,
   `disburse`, `complete`, `withdraw`, `pause`, `resume`, `modify`,
   `cancel`, `Sweep`. Custom values silently break the SundaeSwap
   indexers / dashboards that aggregate treasury actions by `event`.
   An Amaru contingency top-up from the contingency budget is
   mechanically a `disburse` event and MUST emit
   `event: "disburse"`.

Body-shape divergences from the spec (paragraph arrays, `@context`
as an array, presence of `justification`, absence of `txAuthor`) are
deliberate and inherited from the bash-era operator practice; they
are NOT bugs to fix against this principle alone. Per Principle I's
tie-break, **if the bash-recipe shape and the SundaeSwap TOM body
shape disagree, the bash shape wins.** Closing a body-shape gap
requires a separate, deliberate amendment to this constitution.

## Technology Constraints

- GHC 9.6+ (matches `cardano-node-clients`).
- Code dependencies consumed via `source-repository-package` in
  `cabal.project`, each pinned with a nix32 `--sha256:` hash. CHaP is
  enabled. The load-bearing pins are:
  - [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
    — pure `TxBuild` monad and balancer (Principle II).
  - [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
    — `Provider` / `Submitter` / N2C client / devnet helpers
    (Principle III).
- Protocol/schema dependency (non-code): label-1694 rationale
  metadata follows the SundaeSwap-finance/treasury-contracts spec
  pinned in `lib/Amaru/Treasury/AuxData.hs` (Principle VII). The
  pinned spec commit is the source of truth for the `event` enum and
  rationale shape; the validator scripts our tx spends against are
  deployed from the same upstream.
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

**Version**: 0.2.0 | **Ratified**: 2026-05-04 | **Last Amended**: 2026-05-15
