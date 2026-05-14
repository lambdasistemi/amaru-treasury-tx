# Quickstart — Treasury Inspect (operator walkthrough)

This walkthrough is the seed for `docs/inspect.md`. The implement phase
copies it (and trims as needed) to the final docs location.

## What it does

After firing a treasury-touching transaction (swap, disburse, reorganize,
withdraw) you want to know:

- Did the body input get spent?
- Are the SundaeSwap order outputs sitting at the order address waiting
  to be filled?
- What does the treasury balance look like *now*?

`treasury-inspect` answers all three from one read-only command, against
your local cardano-node. No signing, no submission, no key material.

## Prerequisites

- A running cardano-node socket on the relevant network (mainnet, preprod,
  preview).
- The `metadata.json` you would pass to the wizards (`disburse-wizard`,
  `swap-wizard`, `withdraw-wizard`).

## The basic command

```sh
amaru-treasury-tx \
  --node-socket /run/cardano/node.socket \
  --network cardano-mainnet \
  treasury-inspect \
  --metadata mainnet.json
```

By default this prints a human-readable report on the terminal, one
section per scope.

## Filter to one scope

After firing a `network_compliance` swap you usually only care about that
scope.

```sh
amaru-treasury-tx … treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance
```

## Get JSON for automation

When piping to another tool, the output is JSON by default:

```sh
amaru-treasury-tx … treasury-inspect --metadata mainnet.json \
  | jq '.scopes[] | select(.scope == "network_compliance")'
```

To force JSON on a TTY (e.g. for screenshotting the structured shape):

```sh
amaru-treasury-tx … treasury-inspect --metadata mainnet.json --format json
```

## Save JSON to a file alongside a terminal summary

`--out` writes the JSON document to a file. The terminal still shows the
human view when `--format` is `human` (the default on a TTY).

```sh
amaru-treasury-tx … treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance \
  --out network-compliance-after-b5716ae9.json
```

## Reading the output

Each scope section shows:

1. **Treasury UTxOs** — `txid#ix`, ADA amount, USDM amount, any other
   assets present.
2. **Totals** — sum across the scope's UTxOs (ADA, USDM, and a count of
   distinct other-asset entries so unexpected holdings are visible at a
   glance).
3. **Pending SundaeSwap orders** — UTxOs at the SundaeSwap order address
   whose inline datum names *this* scope's treasury as the swap-payout
   destination. Each line shows the ADA committed, the minimum USDM the
   order accepts, and the embedded SundaeSwap fee.

The header has two extra fields operators rely on for "did I point this
at the right deployment":

- `Chain tip` — slot and block hash at the moment the command ran.
- `Deployment NFT` — the policy id of the scope-owners NFT pinned in
  metadata. Different deployment, different policy id.

## What it does *not* do (v1)

- It does not walk back through chain history to show settled swaps.
- It does not look up the aux-data rationale (label 1694) on the
  transaction that placed a pending order.
- It does not compare two metadata files (mainnet vs preprod).

Those are tracked as follow-up issues and need a Cardano history index
(e.g. Kupo) the project does not consume today.

## Exit codes

| Code | Meaning |
|:----:|---------|
| 0    | Report rendered. |
| 2    | Bad invocation: unknown scope, missing flag, malformed metadata. |
| 3    | Node-side problem: socket unreachable, network-magic mismatch. |

## Acceptance smoke (operator-run, not CI)

After the swap submitted as
[`b5716ae9…`](https://cardanoscan.io/transaction/b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e),
running:

```sh
amaru-treasury-tx \
  --node-socket /run/cardano/node.socket \
  --network cardano-mainnet \
  treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance
```

should show:

- One pending UTxO at the SundaeSwap order address for each of the two
  swap-order outputs of `b5716ae9…` (i.e. two `pendingOrders` entries).
- One treasury UTxO at `b5716ae9…#2` (the leftover).
- Chain tip strictly greater than the slot of `b5716ae9…`.
