# CLI Contract: `amaru-treasury-tx`

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)

## Synopsis

```
amaru-treasury-tx --metadata <PATH>
                  [--ttl-seconds <N>]
                  [--blacklist-file <PATH>]
                  [--exclude <TXID#IX>]...
                  [--node-socket <PATH>]
                  [--summary-out <PATH>]
                  <SUBCOMMAND> [args...]
```

## Global flags

| Flag | Type | Default | Meaning |
|---|---|---|---|
| `--metadata <PATH>` | path, **required** | – | Path to a [`metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)-shaped file describing all configured scopes. |
| `--ttl-seconds <N>` | uint | `3600` | Adds `N` seconds to the current wall-clock to derive the `invalid_hereafter` slot. |
| `--blacklist-file <PATH>` | path | – | Newline-separated `txid#ix` to skip during treasury-UTxO selection. |
| `--exclude <TXID#IX>` | repeated | – | Additional UTxO ids appended to the blacklist. |
| `--node-socket <PATH>` | path | `$CARDANO_NODE_SOCKET_PATH` | Path to the cardano-node N2C socket. Required for the `local-node` backend. |
| `--summary-out <PATH>` | path | `<action>.summary.json` in CWD | Destination for the JSON summary (see [`summary-schema.json`](./summary-schema.json)). |

## Subcommands

### `disburse`

```
amaru-treasury-tx [global flags] disburse
  <WALLET_ADDRESS> <AMOUNT> <UNIT> <BENEFICIARY_ADDRESS>
  <SCOPE> <WITNESS_SCOPE>...
```

| Positional | Type | Meaning |
|---|---|---|
| `WALLET_ADDRESS` | bech32 `addr…` | Wallet that pays fee and serves as collateral. |
| `AMOUNT` | integer | Quantity in the given `UNIT` (lovelace for `ada`; smallest USDM unit for `usdm`). |
| `UNIT` | `ada` \| `usdm` | – |
| `BENEFICIARY_ADDRESS` | bech32 `addr…` | Recipient of the disbursement output. |
| `SCOPE` | one of `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`, `contingency` | Scope being charged. |
| `WITNESS_SCOPE` | one or more keyhash hex (28 bytes) | Approving scope-owner keyhashes per the Amaru permissions design. |

Mirrors [`disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh).

### `reorganize`

```
amaru-treasury-tx [global flags] reorganize
  <WALLET_ADDRESS> <AMOUNT> <UNIT> <SCOPE>
```

Mirrors [`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh).

### `withdraw`

```
amaru-treasury-tx [global flags] withdraw <WALLET_ADDRESS> <SCOPE>
```

Mirrors [`withdraw.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/withdraw.sh).

## Output

- **Stdout**: a single line — the unsigned Conway transaction as
  hex-encoded CBOR (no surrounding whitespace, no prefix).
- **Sidecar JSON**: written to `--summary-out` (or
  `<action>.summary.json` in CWD) per
  [`summary-schema.json`](./summary-schema.json).
- **Exit codes**:
  - `0` — success (and for `withdraw` when there are no rewards
    to pull, with a `nothing to withdraw` message on stderr; no
    transaction is emitted).
  - non-zero — a single human-readable error on stderr.

## Examples

```bash
# Disburse 50 ADA from core_development to a vendor, co-approved by
# the ops_and_use_cases scope owner
amaru-treasury-tx \
  --metadata fixtures/metadata.json \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  disburse \
  addr1qxwallet... 50000000 ada \
  addr1q9vendor... \
  core_development \
  f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e

# Merge fragmented core_development UTxOs to a single 100 ADA output
amaru-treasury-tx \
  --metadata fixtures/metadata.json \
  reorganize \
  addr1qxwallet... 100000000 ada core_development

# Pull treasury rewards into the contract for network_compliance
amaru-treasury-tx \
  --metadata fixtures/metadata.json \
  withdraw addr1qxwallet... network_compliance
```
