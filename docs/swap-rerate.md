# Re-rate pending swap orders

`swap-rerate` replaces one or more pending SundaeSwap V3 orders for a
single treasury scope at a new ADA/USDM rate. It is the address-based
operator path shipped across the CLI, `POST /v1/build/swap-rerate`, and
the Operate UI.

Use it when a treasury swap order is still pending and the operator
wants to cancel the old order and submit a replacement order at a new
rate. Use the standalone [swap-cancel](swap.md#cancelling-a-pending-order)
flow when the goal is only to return one pending order to the treasury
without creating a replacement order.

## What re-rate does

The normal run is:

1. Select one treasury scope.
2. Pick the pending orders from that scope.
3. Provide a wallet address. The live runner auto-selects fee fuel,
   collateral, and change UTxOs from that address.
4. Build one atomic cancel-and-reoffer transaction when the selection
   fits current execution-memory, execution-step, and transaction-size
   budgets.
5. If the selection is too large, receive a split fallback plan instead
   of an overflowing transaction.
6. Review the report, witness the unsigned CBOR, attach witnesses, and
   submit.

The command does not sign or submit. It writes unsigned Conway CBOR and
a JSON report, the same handoff shape used by the rest of the operator
pipeline.

## Safety model

The preferred shape is a single atomic transaction: every selected
pending order is cancelled and its replacement order is created in the
same transaction body. That is the only shape that writes unsigned CBOR
for the normal `single_tx` result.

Before writing bytes, the planner checks the current protocol budget. If
the selection exceeds execution memory, execution steps, or transaction
body size, `swap-rerate` writes a `split` report instead of CBOR. The
report names the planner reason, the budget estimate, and ordered split
groups. Treat that as a new operator plan: build, review, witness, and
submit each group deliberately rather than forcing the original
selection into one transaction.

The order spend uses the SundaeSwap V3 order validator as a PlutusV2
script and the `Cancel` redeemer. The Amaru permissions withdraw-zero
path still supplies the treasury scope approval rule, so the final
transaction requires the expected treasury owner witnesses.

## Value and funding rule

Re-rate is not a wallet-funded swap. For each selected order, the old
order's offered ADA amount is conserved and becomes the offered amount
of the replacement order. The new rate only changes the replacement
datum's requested USDM amount.

Each replacement order output must also clear the ledger min-UTxO and
re-fund the Sundae scooper rider. The planner accounts for that
per-order extra lovelace when deriving the replacement output value.

The operator wallet funds fees, collateral, and change only. It must
have pure ADA UTxOs, but it must not be treated as contributing the
traded ADA. If the wallet address has no pure ADA fuel or cannot cover
the fee slack, the live runner rejects the build with a stable wallet
selection diagnostic.

## CLI worked example

Start with the same metadata and node socket setup used by the
[swap recipe](swap.md):

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket

curl -fsSL https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
  -o metadata-mainnet.json
```

Inspect pending orders for the scope, then choose the order UTxOs to
re-rate:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  treasury-inspect \
    --metadata metadata-mainnet.json \
    --scope network_compliance
```

Build the preferred atomic transaction by passing the wallet address and
the selected pending orders:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-rerate \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --wallet-address "$WALLET_ADDR" \
    --order-txin "$ORDER_TXIN_A" \
    --order-txin "$ORDER_TXIN_B" \
    --new-rate 0.47 \
    --validity-hours 28 \
    --out rerate.cbor.hex \
    --report rerate.report.json
```

Use `--all-orders` only when every pending order in the selected scope
should be re-rated together:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-rerate \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --wallet-address "$WALLET_ADDR" \
    --all-orders \
    --new-rate 0.47 \
    --out rerate.cbor.hex \
    --report rerate.report.json
```

On a successful atomic build, the report has `status: "single_tx"` and
the CBOR file is present. On an over-budget selection, the report has
`status: "split"` and no CBOR is written for the combined selection.

## HTTP JSON example

The API exposes the same unsigned build through
`POST /v1/build/swap-rerate`. The request uses the `srr*` field names
from the Haskell JSON type and accepts the wallet address, not manual
wallet or collateral tx-ins:

```bash
curl -fsS \
  -H 'content-type: application/json' \
  -X POST \
  http://127.0.0.1:8080/v1/build/swap-rerate \
  --data-binary @- <<'JSON'
{
  "srrScope": "network_compliance",
  "srrSelectedOrders": [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0",
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#1"
  ],
  "srrNewRate": 0.47,
  "srrWalletAddress": "addr1q..."
}
JSON
```

A single-transaction response carries `srrDecision: "single_tx"` plus
`srrCborHex`, `srrCborEnvelope`, and `srrReport`. A split fallback
carries `srrDecision: "split"`, `srrReason`, and `srrReport`, with no
CBOR. Typed failures use `srrFailureTag` and `srrFailureReason`.

## Operate UI workflow

In the hosted operator app, open **Operate**, choose **Re-rate**, and
select a scope. The UI fetches pending orders for that scope and shows a
checkbox for each order. Select the orders to re-rate, enter the new
ADA/USDM rate, and provide the wallet address in the Funding section.

The build button posts the same request shape as the HTTP example:
`srrScope`, `srrSelectedOrders`, `srrNewRate`, and `srrWalletAddress`.
The result panel shows whether the build produced a single unsigned
transaction or a split fallback.

The committed review screenshot for the address-based workflow is
available in the repository source:
[419-rerate-operate-desktop-1280.png](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/frontend/test/ui-review/419/419-rerate-operate-desktop-1280.png).

## Review, witness, submit

Review `rerate.report.json` before signing. Confirm at least:

- `scope` is the intended treasury scope.
- `status` is `single_tx` before using the CBOR file.
- `selectedOrders` contains only the intended pending order UTxOs.
- `newRate` is the intended ADA/USDM rate.
- each order shows the expected returned and re-offered values.
- the fee and required signing steps are acceptable.

Then produce detached witnesses, attach them, and submit:

```bash
exec 9<<<"$VAULT_PASSPHRASE"

amaru-treasury-tx --network mainnet witness \
  --tx rerate.cbor.hex \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  --out core_development.witness.hex

exec 9<&-

owner_witness_hex="$(tr -d '\n' < core_development.witness.hex)"

amaru-treasury-tx attach-witness \
  --tx rerate.cbor.hex \
  --witness "$owner_witness_hex" \
  --out rerate.signed.cbor.hex

amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  submit --tx rerate.signed.cbor.hex
```

Attach every owner witness required by the order datum and the Amaru
scope approval rule before submission.

## Related operations

- [Swap recipe](swap.md) covers normal new swap order construction,
  quote-derived swap runs, report review, and the shared witness /
  submit pipeline.
- [swap-cancel](swap.md#cancelling-a-pending-order) cancels one pending
  SundaeSwap order back to the treasury without creating a replacement.
- [`POST /v1/build/swap-rerate`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Api/BuildSwapRerate.hs)
  is the HTTP build endpoint used by Operate.
- [Epic #395](https://github.com/lambdasistemi/amaru-treasury-tx/issues/395)
  tracks the broader swap re-rate recovery work.
