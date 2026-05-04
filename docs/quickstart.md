# Quickstart

This document walks through the typical flow once the
CLI is implemented (post-`/speckit.implement`). Until
then it serves as the target UX for the implementation.

## 1. Get the binary

```bash
git clone git@github.com:lambdasistemi/amaru-treasury-tx.git
cd amaru-treasury-tx
nix develop
just build
```

Or, when published, fetch a static binary release from
[GitHub releases][releases].

## 2. Get a metadata file

Use the canonical
[`journal/2026/metadata.json`][metadata] as-is:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
  > metadata.json
```

The CLI never modifies this file; it is read-only input.

## 3. Make sure a node is reachable

The default backend is the local cardano-node. On a
machine with mainnet synced, point the CLI at the
node's N2C socket.

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/node.socket
```

## 4. Build a disburse transaction

```bash
amaru-treasury-tx \
  --metadata metadata.json \
  disburse \
  $WALLET_ADDR \
  50000000 ada \
  $VENDOR_ADDR \
  core_development \
  $WITNESS_KEYHASH \
  > disburse.cbor
```

You now have:

- `disburse.cbor`: the unsigned Conway tx CBOR (hex).
- `disburse.summary.json`: txid, fee, ExUnits per
  script, redeemer indexes — see the
  [summary schema][summary].

## 5. Sign and submit (out of scope for this CLI)

Pipe `disburse.cbor` into your preferred signer
(hardware wallet, [`cardano-wallet-sign`][cws], MPC
service). Then `cardano-cli transaction submit` (or any
other submission path) to broadcast.

## 6. Reorganize and withdraw

```bash
# Merge fragmented core_development UTxOs to a 100 ADA output
amaru-treasury-tx --metadata metadata.json reorganize \
  $WALLET_ADDR 100000000 ada core_development > reorganize.cbor

# Pull treasury rewards into the network_compliance contract
amaru-treasury-tx --metadata metadata.json withdraw \
  $WALLET_ADDR network_compliance > withdraw.cbor
```

## 7. Validity bound

By default the CLI sets `invalid_hereafter =
currentSlot + 3600` (one hour). Override with
`--ttl-seconds 7200` if your signing ceremony is slow.

## 8. Treasury-UTxO blacklist

If a particular treasury UTxO must be skipped during
selection (for example, because it is reserved for a
different operation), supply it via
`--blacklist-file blacklist.txt` (newline-separated
`txid#ix`) or repeat `--exclude txid#ix`.

## 9. Re-running for golden tests

The `test/fixtures/` tree carries one input bundle per
supported action. A failing golden means the bash
recipe and this CLI have diverged; the divergence must
be analysed and one of them updated.

[releases]: https://github.com/lambdasistemi/amaru-treasury-tx/releases
[metadata]: https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json
[summary]: https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/001-treasury-tx-cli/contracts/summary-schema.json
[cws]: https://github.com/lambdasistemi/cardano-wallet-sign
