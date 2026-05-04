# Implementation Plan: Treasury Transaction CLI

**Branch**: `001-treasury-tx-cli-plan` | **Date**: 2026-05-04 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification at [`specs/001-treasury-tx-cli/spec.md`](./spec.md)

## Summary

Build a Haskell CLI (`amaru-treasury-tx`) that emits unsigned Conway
transactions for the three Amaru treasury actions: `disburse`,
`reorganize`, `withdraw`. The behavioural source of truth is the bash
recipe set under
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026).

Transaction-building logic is expressed as **pure** programs in the
`TxBuild q e a` operational-monad DSL provided by
[`Cardano.Node.Client.TxBuild`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs).
All effects are lifted through the existing
[`Cardano.Node.Client.Provider`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/Provider.hs)
record-of-functions interface. The default `Provider` is backed by
N2C LocalStateQuery against a local cardano-node socket
(`mkN2CProvider`); the optional Blockfrost-backed `Provider` is a
follow-up increment, not part of MVP.

## Technical Context

| Field | Value |
|---|---|
| Language | Haskell, GHC 9.6+ (matches `cardano-node-clients`) |
| Primary deps | [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients) (TxBuild DSL, N2C Provider), `cardano-ledger-conway`, `plutus-tx` (`ToData`), `bytestring`, `aeson`, `optparse-applicative`, `text` |
| Build | Cabal + Nix flake (haskell.nix, IOG cache) |
| Testing | Hspec + checked-in golden CBOR fixtures + QuickCheck for property-level checks |
| Target Platform | Linux (mainnet/preprod/preview); CI on self-hosted NixOS runner |
| Project Type | Single CLI executable + library |
| Performance Goals | Build a transaction in < 30 s against a working backend (per [SC-001](./spec.md#measurable-outcomes)) |
| Constraints | Conway era only; Plutus v3; no signing or submission; build CBOR matches bash recipes for golden fixtures |
| Scale/Scope | Five known scopes; up to a few treasury UTxOs per build; single-purpose CLI |
| Data sources on this machine | Mainnet node socket at `/code/cardano-mainnet/ipc/node.socket`; Blockfrost preprod/mainnet keys per [`reference_blockfrost_preprod.md`](https://github.com/paolino/llm-settings) |

## Constitution Check

*Gate before Phase 0 research and again after Phase 1 design.*

| Principle | Compliance | Notes |
|---|---|---|
| I — Faithful port of bash recipes | ✅ | One Haskell module per bash entry point; redeemer Plutus-data shapes pinned in `Amaru.Treasury.Redeemer`; metadata.json shape consumed unchanged. Divergences listed under "Justified Divergences". |
| II — Pure builders, impure shell | ✅ | All `Tx.Disburse`, `Tx.Reorganize`, `Tx.Withdraw` modules expose `TxBuild q e a` programs; no IO. Effects live only in `app/.../Main.hs` and `Backend/N2C.hs`. |
| III — Pluggable data source, local-node default | ✅ | The plan reuses `Cardano.Node.Client.Provider` (record of functions) rather than inventing a separate typeclass. Default backend = `mkN2CProvider`; Blockfrost backend deferred to a follow-up increment (out of MVP). |
| IV — Build, never sign or submit | ✅ | The CLI emits CBOR + summary JSON only. There are no signing or submission code paths; the cabal file does not depend on any signing libraries. |
| V — TDD with golden CBOR fixtures | ✅ | Phase 1 produces four golden fixtures before implementation lands. Bodies are committed; tests are written first and must fail before any builder code lands. |
| VI — Hackage-ready Haskell | ✅ | Mirrors `cardano-node-clients` cabal+nix layout: `common warnings` block with `-Werror`, fourmolu 70-col, `cabal check` clean, Haddock on every export. |

### Justified divergences from the bash recipes

| Divergence | Reason |
|---|---|
| Validity bound is `currentSlot + buffer` (default 1 hour) using `Provider.posixMsToSlot`, instead of `slot + slotsToEpochEnd - 1` per [`compute_validity_period.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/compute_validity_period.sh) | The `Provider` does not expose `slotsToEpochEnd` today. Buffer-based validity is correct for any era and matches what most wallets emit; the bash strategy is harmless but unnecessary. The buffer is a CLI flag (`--ttl-seconds`, default 3600) so users can match the bash if they want. Documented in user-facing help and `quickstart.md`. |
| Fuel UTxO is a single UTxO, not a multi-UTxO selection | Matches [`resolve_fuel.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/resolve_fuel.sh), which `head -1`s the wallet UTxOs. Multi-UTxO fuel is explicitly out-of-scope per [`spec.md`](./spec.md#out-of-scope). |

## Project Structure

### Documentation (this feature)

```text
specs/001-treasury-tx-cli/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── cli.md           # CLI command contract
│   ├── metadata-schema.json   # mirrors journal/2026/metadata.json
│   └── summary-schema.json    # tx summary sidecar
├── checklists/
│   └── requirements.md  # Spec quality checklist (already present)
└── tasks.md             # Phase 2 output (separate /speckit.tasks step)
```

### Source code (repository root)

```text
amaru-treasury-tx/
├── flake.nix
├── nix/
│   ├── project.nix          # haskell.nix cabalProject' (CHaP, IOG cache)
│   ├── checks.nix           # build, unit, golden, lint derivations
│   ├── apps.nix             # runnable wrappers over checks
│   └── fix-libs.nix         # crypto pkgconfig overrides (mirrored from cardano-node-clients)
├── cabal.project            # SRP pin: cardano-node-clients @ fix/eval-retry (nix32 sha)
├── amaru-treasury-tx.cabal  # library + exe + unit-tests + e2e-tests
├── README.md
├── justfile                 # build, unit, format, hlint, ci
├── lib/
│   └── Amaru/
│       └── Treasury/
│           ├── Metadata.hs         # parse metadata.json
│           ├── Scope.hs            # ScopeId sum type + lookups
│           ├── Constants.hs        # USDM_POLICY, USDM_TOKEN
│           ├── Redeemer.hs         # ToData instances matching bash exactly
│           ├── Backend.hs          # alias around Cardano.Node.Client.Provider
│           ├── Backend/N2C.hs      # local-node Provider construction
│           ├── Tx/
│           │   ├── Disburse.hs     # TxBuild q e () program
│           │   ├── Reorganize.hs
│           │   └── Withdraw.hs
│           └── Summary.hs          # tx summary JSON encoder
├── app/
│   └── amaru-treasury-tx/
│       └── Main.hs                 # optparse-applicative + Provider wiring
├── test/
│   ├── unit/
│   │   ├── Spec.hs                 # hspec-discover entry
│   │   ├── Amaru/Treasury/RedeemerSpec.hs
│   │   ├── Amaru/Treasury/MetadataSpec.hs
│   │   └── Amaru/Treasury/Tx/GoldenSpec.hs
│   └── fixtures/
│       ├── metadata.json           # checked-in copy of journal/2026/metadata.json
│       ├── ada-disburse/
│       │   ├── inputs.json         # synthesized utxos + intent
│       │   └── body.cbor           # golden body (no ExUnits)
│       ├── usdm-disburse/
│       ├── reorganize/
│       └── withdraw/
└── docs/
    ├── index.md
    └── architecture.md
```

**Structure decision**: Single library (`lib/`) + single executable
(`app/amaru-treasury-tx/`) + unit and e2e test suites. Mirrors the
[`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
layout 1:1 so devs moving between repos have zero context-switching
cost.

## Phase 0 — Outline & Research

Tasks (results consolidated in [`research.md`](./research.md)):

1. **Pin `cardano-node-clients`**: identify the latest commit on the
   [`fix/eval-retry`](https://github.com/lambdasistemi/cardano-node-clients/tree/fix/eval-retry)
   branch, prefetch via `nix flake prefetch
   github:lambdasistemi/cardano-node-clients/<sha>`, convert to
   nix32, record the resulting SRP block.

2. **Sundae redeemer constructor numbers**: cross-check that
   [`Disburse`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak)
   is constructor `3` and `Reorganize` is constructor `0` against
   the latest `treasury.ak` and the bash literals (`constructor: 3`,
   `constructor: 0`). Record the full constructor → variant mapping
   for completeness.

3. **Plutus-data encoding parity**: verify that `plutus-tx`'s
   `ToData` produces a byte-identical CBOR encoding for the disburse
   map vs. the `cardano-cli transaction build` path used by bash.
   Document any canonical-CBOR caveats (definite vs indefinite map
   encoding) and pick a deterministic encoding.

4. **`Provider` capability gap analysis**: confirm that
   [`Cardano.Node.Client.Provider`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/Provider.hs)
   provides everything we need (UTxO lookup by address and TxIn,
   protocol parameters, evaluator, POSIX→slot). Identify the single
   gap: tip slot for the validity bound. Decide between
   (a) extending `Provider` upstream with `queryTipSlot` or
   (b) computing the validity bound from wall-clock time and
   `posixMsToSlot`. Pick (b) for MVP.

5. **Stake-rewards balance for `withdraw`**: the bash recipe queries
   `ccli query stake-address-info` to know how much to pull. The
   current `Provider` doesn't expose this. Decide: extend the
   `Provider` upstream with `queryStakeRewards :: Credential -> m
   Coin`. For MVP, this is added in `cardano-node-clients` first; we
   pin to the bumped commit. (Tracked in research.md.)

6. **Auxiliary metadata shape**: read
   [`treasury_instance_metadata.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/treasury_instance_metadata.sh)
   to capture the exact aux-data structure that goes into every
   spending transaction, and replicate as a Haskell `Metadatum`
   builder.

7. **Blacklist input**: decide the CLI surface for the UTxO blacklist
   (matches [`is_blacklisted.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/is_blacklisted.sh)).
   Pick a file form (`--blacklist-file <path>`, newline-separated
   `txid#ix`) **and** repeated `--exclude <txid#ix>` flags.

**Output**: [`research.md`](./research.md) with one decision block per task.

## Phase 1 — Design & Contracts

### 1. Data model — [`data-model.md`](./data-model.md)

| Entity | Module | Purpose |
|---|---|---|
| `ScopeId` | `Amaru.Treasury.Scope` | Sum type: `CoreDevelopment | OpsAndUseCases | NetworkCompliance | Middleware | Contingency`; `Aeson` instances; total parser |
| `ScriptRef` | `Amaru.Treasury.Metadata` | `(ScriptHash, TxIn)` pair (hash + `deployed_at`) |
| `ScopeMetadata` | `Amaru.Treasury.Metadata` | `{owner :: Maybe KeyHash, address :: Addr, treasury :: ScriptRef, permissions :: ScriptRef, registry :: ScriptRef}` (`Maybe` covers contingency) |
| `TreasuryMetadata` | `Amaru.Treasury.Metadata` | `{scopeOwners :: TxIn, treasuries :: Map ScopeId ScopeMetadata}` |
| `Unit` | `Amaru.Treasury.Constants` | Sum type: `ADA | USDM` plus the deployed `USDM_POLICY` / `USDM_TOKEN` byte strings |
| `DisburseIntent` | `Amaru.Treasury.Tx.Disburse` | `{wallet :: Addr, amount :: Integer, unit :: Unit, beneficiary :: Addr, scope :: ScopeId, witnesses :: [KeyHash]}` |
| `ReorganizeIntent` | `Amaru.Treasury.Tx.Reorganize` | `{wallet :: Addr, amount :: Integer, unit :: Unit, scope :: ScopeId}` |
| `WithdrawIntent` | `Amaru.Treasury.Tx.Withdraw` | `{wallet :: Addr, scope :: ScopeId}` |
| `TxSummary` | `Amaru.Treasury.Summary` | `{txid, feeLovelace, redeemers :: [RedeemerSummary]}` with JSON encoder |

### 2. CLI contract — [`contracts/cli.md`](./contracts/cli.md)

```text
amaru-treasury-tx --metadata <path>
                  [--ttl-seconds N] [--blacklist-file <path>]
                  [--exclude <txid#ix>]...
                  [--node-socket <path>]
                  [--summary-out <path>]
                  <subcommand> [args...]

Subcommands:
  disburse <WALLET> <AMOUNT> <UNIT> <BENEFICIARY> <SCOPE>
           <WITNESS_SCOPE>...
  reorganize <WALLET> <AMOUNT> <UNIT> <SCOPE>
  withdraw <WALLET> <SCOPE>

UNIT  ::= ada | usdm
SCOPE ::= core_development | ops_and_use_cases | network_compliance
        | middleware | contingency
```

Outputs: unsigned Conway tx CBOR (hex) on stdout; summary JSON at
`--summary-out` (default `<action>.summary.json` in CWD). Exit 0
on success, non-zero on any failure with one-line stderr message.

### 3. Metadata schema — [`contracts/metadata-schema.json`](./contracts/metadata-schema.json)

JSON Schema mirroring [`journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json):
top-level `scope_owners` (UTxO ref string) and `treasuries` (map of
scope name → `{owner, budget?, address, treasury_script,
permissions_script, registry_script}` with each script holding `hash`
+ `deployed_at`). Used to validate user-supplied files at load time
and to drive the parser.

### 4. Summary schema — [`contracts/summary-schema.json`](./contracts/summary-schema.json)

```json
{
  "txid": "hex32",
  "fee_lovelace": 285217,
  "redeemers": [
    { "purpose": "spend|withdraw|mint|publish",
      "index": 0,
      "ex_units": { "mem": 12345, "steps": 67890 } }
  ]
}
```

### 5. Quickstart — [`quickstart.md`](./quickstart.md)

End-to-end example: clone, `nix develop`, `just build`, run
`amaru-treasury-tx --metadata fixtures/metadata.json disburse …`
against `/code/cardano-mainnet/ipc/node.socket`, then sign and
submit with the user's separate signer.

### 6. Constitution re-check (post-design)

| Principle | Status |
|---|---|
| I | ✅ — bash 1:1 in module names, redeemer shapes, metadata fields |
| II | ✅ — `Tx/Disburse.hs`, `Tx/Reorganize.hs`, `Tx/Withdraw.hs` are pure `TxBuild` programs |
| III | ✅ — `Backend.hs` is a thin re-export of `Provider`; `Backend/N2C.hs` is the only impure module |
| IV | ✅ — no signing/submission deps; cabal `build-depends` audited |
| V | ✅ — golden fixtures in `test/fixtures/`; tests written before builders |
| VI | ✅ — `common warnings` mirrored from `cardano-node-clients`; `cabal check` clean |

## Complexity Tracking

No constitution-violating complexity added. The original
"Backend typeclass" idea from the constitution was simplified at
plan time: we reuse `Cardano.Node.Client.Provider` (record of
functions, isomorphic to a typeclass for our purposes) rather than
introducing a separate typeclass. This is recorded in Constitution
Principle III with no violation flagged.

## Out of scope (deferred to follow-up specs)

- Blockfrost-backed `Provider` (Phase 2 spec).
- Multi-UTxO fuel selection.
- The Sundae `Fund` redeemer.
- Reference-script publishing and registry/scopes minting (handled
  by the existing [`recipes/`](https://github.com/pragma-org/amaru-treasury/tree/main/recipes)).
- Mainnet vs preprod CLI plumbing — the `Provider` already encodes
  network through the socket / API key.
- MkDocs site (will be added once content stabilises).
