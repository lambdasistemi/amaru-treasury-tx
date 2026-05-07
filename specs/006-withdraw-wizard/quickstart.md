# Quickstart: Withdraw Wizard

This page describes the target operator flow once feature 006 is
implemented. It is not an implementation guide for the current release.

## 1. Point at a node

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
```

Preprod is the expected first live oracle path because mainnet treasury
reward balances are currently zero in issue #45/#17 context.

## 2. Fetch metadata

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
  -o metadata.json
```

The wizard treats this file as an untrusted hint and verifies consumed
fields against the on-chain registry.

## 3. Produce an intent

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network preprod \
  withdraw-wizard \
    --wallet-addr addr_test1... \
    --metadata metadata.json \
    --scope core_development \
    --validity-hours 6 \
    --log withdraw-wizard.log \
    --out withdraw.intent.json
```

If the selected treasury reward account has zero rewards, the command
exits 0 and writes no `withdraw.intent.json`.

## 4. Build unsigned CBOR

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent withdraw.intent.json \
    --log withdraw-build.log \
    --out withdraw.cbor.hex
```

The intent network is the source of truth. `tx-build` probes the socket
network before querying UTxOs or rewards.

## 5. Pipe form

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network preprod \
  withdraw-wizard \
    --wallet-addr addr_test1... \
    --metadata metadata.json \
    --scope core_development \
    --validity-hours 6 \
  | amaru-treasury-tx \
      --node-socket "$CARDANO_NODE_SOCKET_PATH" \
      tx-build \
        --out withdraw.cbor.hex
```

Wizard trace lines must go to stderr or `--log`; stdout is reserved for
the JSON pipe.

## 6. Developer golden

The MVP fixture is synthetic until issue #17 records a live preprod
reward oracle:

```bash
nix develop --quiet -c just golden withdraw
```

The golden should decode `test/fixtures/withdraw/synthetic/intent.json`,
load the frozen `ChainContext`, rebuild the unsigned body, and compare
to `expected.cbor`.
