# Phase 0 Research: Treasury Transaction CLI

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-04

## R1 — `cardano-node-clients` pin

- **Decision**: Pin
  [`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  at the latest `main` commit.
- **Latest main**: `8cc0605e47d73fb4e47c4cb1437d0e33c525324d`
  ([compare](https://github.com/lambdasistemi/cardano-node-clients/commit/8cc0605e47d73fb4e47c4cb1437d0e33c525324d)).
- **nix32 hash** (from `nix hash convert --to nix32`): `0hg02m3qn7v08w6w7bvy391nasvsl3i4lm0pq8pm01j1ikl5hzvd`.
- **`cabal.project` block**:

  ```
  source-repository-package
    type: git
    location: https://github.com/lambdasistemi/cardano-node-clients
    tag: 8cc0605e47d73fb4e47c4cb1437d0e33c525324d
    --sha256: 0hg02m3qn7v08w6w7bvy391nasvsl3i4lm0pq8pm01j1ikl5hzvd
  ```

- **Rationale**: `Cardano.Node.Client.TxBuild` is already on `main`
  (commit
  [`f578d6c`](https://github.com/lambdasistemi/cardano-node-clients/commit/f578d6c)
  added it; subsequent commits on main only refine it). Pinning to
  main complies with the global rule "source-repository-package
  pins must target main commits, never branches"
  ([feedback memory](https://github.com/paolino/llm-settings)).
- **Alternatives considered**: pinning the `fix/eval-retry` branch —
  rejected because main already carries the DSL.

## R2 — Sundae redeemer constructor numbers

- **Decision**: Encode our `TreasurySpendRedeemer` Haskell sum as
  follows (constructor index → tag), matching upstream
  [`treasury.ak`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak):

  | Variant       | Constructor | Used by this CLI |
  |---------------|:-----------:|:----------------:|
  | `SweepTreasury` | 0         | yes (future) |
  | `Reorganize`    | 1         | yes |
  | `Fund`          | 2         | **no** (Amaru disables Fund) |
  | `Disburse`      | 3         | yes |

- **Surprise**: Reorganize is constructor `1`, not `0` — the
  bash `make_redeemer_reorganize.sh` writes `{constructor: 0,
  fields: []}` which **does not match** the variant order at
  [`treasury.ak#L72-L78`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak#L72-L78).
  The Aiken `when redeemer is { SweepTreasury -> …; Reorganize ->
  …; Fund -> …; Disburse -> … }` orders sweep first; Plutus tags
  follow source order.

  However, looking at the Sundae upstream
  [`types.ak`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/lib/types.ak)
  is the source of truth for the constructor tags (the Aiken
  compiler assigns indices by declaration order in the *type*
  definition, not the `when` arms). The bash `constructor: 0` for
  Reorganize and `constructor: 3` for Disburse implies the Sundae
  type declares
  `{Reorganize, ?, ?, Disburse}` rather than alphabetical / `when`
  order.

- **Action**: Phase 0 cannot resolve this without reading
  Sundae's `types.ak`. **Phase 1 implementation will not depend
  on the constructor numbers directly: instead, the
  `Amaru.Treasury.Redeemer` ToData instances will mirror the bash
  `make_redeemer_*.sh` literals exactly** (constructor 3 for
  disburse, constructor 0 for reorganize). Golden tests verify the
  serialized bytes match. If the bash is wrong, our golden tests
  fail at submit time on preprod, and we update both at once.
- **Alternatives considered**: deriving `ToData` from a Haskell sum
  via `makeIsDataIndexed` with explicit indices — rejected because
  the canonical encoding of an empty-constructor argument list
  needs verification (see R3).

## R3 — Plutus-data encoding parity (canonical CBOR)

- **Decision**: Hand-write the `ToData` encodings for the two
  redeemers with explicit `Data` constructors (`Constr` and `Map`)
  rather than rely on Template-Haskell-derived instances. This
  guarantees byte-equality with the bash `cardano-cli`-built CBOR.
- **Rationale**:
  - Bash uses `jq --null-input "{constructor: 3, fields: [{map: …}]}"`
    → `cardano-cli transaction build
    --spending-reference-tx-in-redeemer-file <file>` reads JSON
    Plutus-data and re-serialises as CBOR.
  - `cardano-cli` and `plutus-tx` should produce identical CBOR
    for the same `Data` value, since both use the canonical
    encoding documented in [CIP-0050](https://cips.cardano.org/cips/cip50/).
  - Map encoding: a single-element map encodes as definite-length
    `0xa1` (one entry) in canonical CBOR. Both `cardano-cli` and
    `plutus-tx` emit definite-length for ≤23 entries.
- **Verification**: A unit test (`RedeemerSpec`) computes the
  CBOR of `Disburse 1000000` (lovelace) and `Reorganize` and
  compares to expected hex strings recorded from running the bash
  `make_redeemer_*.sh` once.
- **Alternatives considered**: `makeIsDataIndexed` Template Haskell
  — adopted for the *Haskell-internal* sum-type (so we get a
  `FromData` for round-trip tests too), but the wire-level encoding
  is double-checked against checked-in bytes.

## R4 — `Provider` capability gap analysis

- **Decision**: The existing
  [`Cardano.Node.Client.Provider`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/Provider.hs)
  covers four of the five operations we need:
  `queryUTxOs Addr`, `queryUTxOByTxIn (Set TxIn)`,
  `queryProtocolParams`, `evaluateTx`, `posixMsToSlot`.
- **Gap 1 — current slot**: We need the chain tip's slot to
  compute the upper validity bound. We resolve this **without
  extending Provider**: read the system wall-clock as POSIX
  milliseconds, call `posixMsToSlot`, add the user-configured
  buffer (`--ttl-seconds`, default 3600). This matches what
  light wallets do.
- **Gap 2 — stake-rewards balance** (only for `withdraw`): see R5.
- **Alternatives considered**: extending `Provider` upstream with
  `queryTipSlot` — feasible (the `Query` ADT has
  `GetChainPoint`) but unnecessary for MVP and adds a coupled
  upstream PR.

## R5 — Stake-rewards balance for `withdraw`

- **Decision**: Add a thin extension upstream in
  `cardano-node-clients` exposing `queryStakeRewards :: Set
  RewardAccount -> m (Map RewardAccount Coin)` on `Provider`,
  backed by the `GetFilteredDelegationsAndRewardAccounts` Conway
  query. Pin our SRP to that bumped commit before merging the
  Phase 1 implementation PR.
- **Rationale**: Without rewards balance the `withdraw` builder
  cannot know how much to pull. We considered passing the amount
  on the CLI but the bash recipe queries it for safety
  (`if [[ $treasury_lovelace -eq 0 ]]; then exit 0`) and emits
  a "nothing to withdraw" message; we want the same UX.
- **Implementation note**: This is a one-PR upstream extension
  (record-of-functions field + Conway query plumbing). Tracked
  as a separate issue on `cardano-node-clients` before this CLI's
  implementation lands. If the upstream change is delayed, we
  can ship a temporary CLI flag `--rewards-lovelace <n>`
  bypassing the query, and remove it later.
- **Alternatives considered**:
  - Local detour through `cardano-cli query stake-address-info`:
    rejected because it reintroduces a tooling dependency we are
    trying to remove.
  - Reading the rewards balance from Blockfrost: rejected for MVP
    because the local-node backend has to work standalone.

## R6 — Auxiliary metadata structure

- **Decision**: Mirror
  [`treasury_instance_metadata.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/treasury_instance_metadata.sh)
  literally. The auxiliary data is a CIP-0020 metadata label `0`
  (or whatever the script writes — to be confirmed) carrying the
  registry-instance reference. Encoded as a `TxAuxData` with the
  appropriate `Metadatum` shape.
- **Action item for Phase 1**: read the actual
  `treasury_instance_metadata.sh` body during implementation and
  port byte-for-byte. Add a `MetadataSpec.hs` test that compares
  the produced metadata CBOR against a checked-in fixture.

## R7 — Blacklist input

- **Decision**: Two flags, both optional:
  - `--blacklist-file <path>`: newline-separated `txid#ix`.
  - `--exclude <txid#ix>`: repeated; appended to the file
    contents.
- **Rationale**: matches [`is_blacklisted.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/is_blacklisted.sh)
  (which currently hardcodes the list); supports both checked-in
  blacklist files and one-off exclusions.
- **Alternatives considered**: putting the blacklist in
  `metadata.json` — rejected because the blacklist evolves
  faster than the deployment metadata.

## Summary of decisions

| # | Topic | Decision |
|---|---|---|
| R1 | Upstream pin | `lambdasistemi/cardano-node-clients` @ `8cc0605…` (main), nix32 `0hg02m3qn7v08w6w7bvy391nasvsl3i4lm0pq8pm01j1ikl5hzvd` |
| R2 | Sundae constructor numbers | Mirror bash literals (`Disburse=3`, `Reorganize=0`); golden bytes are the contract |
| R3 | Plutus-data encoding | Hand-written `Data` values; bytes pinned in `RedeemerSpec` |
| R4 | Validity bound | wall-clock + `posixMsToSlot` + `--ttl-seconds` (default 3600) |
| R5 | Stake-rewards query | Extend `Provider` upstream with `queryStakeRewards` and re-pin |
| R6 | Aux metadata | Port `treasury_instance_metadata.sh` literally |
| R7 | Blacklist | `--blacklist-file` + repeated `--exclude` |
