# Inspecting the treasury

`treasury-inspect` is a read-only snapshot of treasury balances and
pending SundaeSwap orders, one section per scope. It replaces the
manual two-`cardano-cli` workflow operators run after firing a swap
or disburse.

## What it does

After firing a treasury-touching transaction (swap, disburse,
reorganize, withdraw) you usually want to know:

- Did the body input get spent?
- Are the SundaeSwap order outputs sitting at the order address,
  waiting to be filled?
- What does the treasury balance look like *now*?

`treasury-inspect` answers all three from one read-only command,
against your local cardano-node. No signing, no submission, no
key material.

## Prerequisites

- A running cardano-node socket on the relevant network (mainnet,
  preprod, preview).
- The `metadata.json` you pass to the other wizards
  (`disburse-wizard`, `swap-wizard`, `withdraw-wizard`).

## Basic command

```sh
amaru-treasury-tx \
  --node-socket /run/cardano/node.socket \
  --network mainnet \
  treasury-inspect \
  --metadata mainnet.json
```

By default this prints a human-readable report on the terminal, one
section per scope.

## Profile-based command

If your operator settings live in `treasury.yaml`, the selected profile
can provide the node socket, network, metadata path, default scope, and
swap-order address:

```sh
amaru-treasury-tx \
  --config treasury.yaml \
  --profile acme \
  treasury-inspect
```

In that form `treasury-inspect` can omit `--metadata` and `--scope`
because it reads `metadataPath` and `defaultScope` from the profile.
The command still verifies the metadata against the on-chain registry
before reporting balances.

Explicit command-line flags remain the highest-precedence source. Use
them to override one profile value for a single run:

```sh
amaru-treasury-tx \
  --config treasury.yaml \
  --profile acme \
  treasury-inspect \
  --metadata emergency-metadata.json \
  --scope middleware \
  --swap-order-address addr1...
```

The old flag-only form still works, and so does the
`CARDANO_NODE_SOCKET_PATH` compatibility environment variable when
`--node-socket` / `AMARU_TREASURY_NODE_SOCKET` is not set.

## Filter to one scope

After firing a `network_compliance` swap you usually only care about
that scope.

```sh
amaru-treasury-tx … treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance
```

## JSON for automation

When piping to another tool, the output is JSON by default:

```sh
amaru-treasury-tx … treasury-inspect --metadata mainnet.json \
  | jq '.scopes[] | select(.scope == "network_compliance")'
```

To force JSON on a TTY (e.g. for screenshotting the structured
shape):

```sh
amaru-treasury-tx … treasury-inspect --metadata mainnet.json \
  --format json
```

## Save JSON to a file alongside a terminal summary

`--out` writes the JSON document to a file. The terminal still shows
the human view when `--format` is `human` (the default on a TTY).

```sh
amaru-treasury-tx … treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance \
  --out network-compliance-after-b5716ae9.json
```

## Reading the output

Each scope section shows:

1. **Treasury UTxOs** — `txid#ix`, ADA amount, USDM amount, and a
   count of any other-asset entries if the UTxO carries them.
2. **Totals** — sum across the scope's UTxOs.
3. **Pending SundaeSwap orders** — UTxOs at the SundaeSwap order
   address whose inline datum names *this* scope's treasury as the
   swap-payout destination. Each line shows the ADA committed, the
   minimum USDM the order will accept, and the embedded SundaeSwap
   protocol fee.

The header has two extra fields operators rely on for "did I point
this at the right deployment":

- **Chain tip** — slot at the moment the command ran. The block
  hash is left empty in v1 (the underlying Provider does not expose
  it; the slot alone is sufficient to spot drift).
- **Deployment anchor** — the scope-owners-NFT UTxO outref pinned
  in metadata's `scope_owners` field. Different deployments have
  different outrefs.

## JSON shape

The output is documented by a JSON Schema 2020-12 document at
[`docs/assets/treasury-inspect-schema.json`](assets/treasury-inspect-schema.json).
The schema is validated by `just schema-check` so the binary's
emitted shape and the on-disk schema cannot drift.

## What it does *not* do (v1)

- It does not walk back through chain history to show settled swaps.
- It does not look up the aux-data rationale (label 1694) on the
  transaction that placed a pending order.
- It does not compare two metadata files (mainnet vs preprod).
- It does not cancel a pending order. Cancellation is tracked as
  [#116](https://github.com/lambdasistemi/amaru-treasury-tx/issues/116);
  it consumes a `pendingOrders[].outref` from this report to drive
  the cancel transaction.

The first three are tracked as follow-up issues and would need a
Cardano history index (e.g. Kupo) the project does not consume today.

## Non-mainnet networks

The SundaeSwap V3 order address is pinned to the mainnet value as
the default. For preprod or preview testing, pass the network's
order address explicitly:

```sh
amaru-treasury-tx … treasury-inspect \
  --metadata preprod.json \
  --swap-order-address addr_test1…
```

If you skip it on preprod/preview, the report's `pendingOrders`
sections will be empty because no orders exist at the mainnet
address there.

## Exit codes

| Code | Meaning |
|:----:|---------|
| 0    | Report rendered. |
| 1    | Bad command-line: optparse-applicative could not parse the flags (unknown scope name, unknown `--format` value, etc.). |
| 2    | Bad invocation at runtime: metadata missing or malformed, requested scope absent from metadata, `--node-socket` not set. Diagnosis on stderr. |
| 3    | Node-side problem: socket connection failure, network-magic mismatch reported by the local-state-query handshake. |

## Acceptance smoke (operator-run, not CI)

After the swap submitted as
[`b5716ae9…`](https://cardanoscan.io/transaction/b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e),
running:

```sh
amaru-treasury-tx \
  --node-socket /run/cardano/node.socket \
  --network mainnet \
  treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance
```

should show:

- One pending UTxO at the SundaeSwap order address for each of the
  two swap-order outputs of `b5716ae9…` (i.e. two `pendingOrders`
  entries).
- One treasury UTxO at `b5716ae9…#2` (the leftover).
- Chain tip slot strictly greater than the slot at which
  `b5716ae9…` was included.
