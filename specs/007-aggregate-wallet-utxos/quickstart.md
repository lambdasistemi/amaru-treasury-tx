# Quickstart: Aggregated wallet fuel for a swap

End-to-end smoke recipe for the post-feature `swap-wizard | tx-build` pipe
against an operator wallet whose ADA is split across multiple pure-ADA UTxOs.

## Prerequisites

- A running mainnet `cardano-node` socket (or preprod, with appropriate
  `--network preprod` and a preprod-aware wizard config).
- `amaru-treasury-tx` built locally:

  ```bash
  nix run .#default -- --help
  ```

- Mainnet operator wallet at a known bech32 address whose pure-ADA UTxOs
  sum to at least the 2 ADA fee/change slack but whose largest single
  pure-ADA UTxO is less than that target. (To set this up cleanly: send
  three small UTxOs of e.g. 1.2 / 0.7 / 0.3 ADA to the wallet from any
  funding source.)
- The corresponding `metadata.json` (mainnet manifest) on disk.

## Smoke recipe

```bash
WALLET=addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz

./amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network mainnet \
    swap-wizard \
        --wallet-addr "$WALLET" \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 10 \
        --min-rate 0.25 \
        --validity-hours 12 \
        --description "Smoke for #65" \
        --justification "Smoke for #65" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer ops_and_use_cases \
        --log wizard.log \
  | ./amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
            --log build.log \
            --out swap.cbor.hex
```

## Expected post-feature behaviour

1. **Wizard log** (`wizard.log`) contains a `WeWalletUtxoSelected` line
   listing the head UTxO + N extra UTxOs whose cumulative ADA covers
   `walletTarget = 2 ADA`. The head is the largest pure-ADA UTxO at
   `$WALLET`.

2. **Wizard exit code** is 0; an intent.json is emitted on stdout
   containing:

   ```json
   "wallet": {
     "txIn": "<largest-pure-ada-utxo-ref>",
     "extraTxIns": [
       "<second-largest-pure-ada-utxo-ref>",
       "..."
     ],
     "address": "addr1qx9aqvsf..."
   }
   ```

   `extraTxIns` is canonically present even when empty.

3. **Builder log** (`build.log`) reports balance success; no
   `BalanceFailed (InsufficientFee ...)` exception. The output `swap.cbor.hex`
   contains an unsigned Conway tx whose body inputs are the union of the
   treasury-selected UTxOs ∪ `wallet.txIn` ∪ `wallet.extraTxIns`, with
   `collateralInputs = {wallet.txIn}` only.

## Failure-mode smoke (P2)

Repeat against a wallet with total pure-ADA below the target (e.g. 1 ADA
across three dust UTxOs):

```bash
# expected wizard exit:
amaru-treasury-tx: wallet shortfall: address addr1...
  available: 1_000_000 lovelace
  required:  2_000_000 lovelace (2 ADA fee/change slack)
exit 3
```

The wizard exits 3 (the existing `WeAborted` exit code); no intent.json
bytes appear on stdout; the builder is never invoked.

## Backward-compatibility smoke (P3)

Run `tx-build` directly against a checked-in pre-feature fixture:

```bash
./amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" \
    tx-build \
        --intent test/fixtures/swap/intent.json \
        --out legacy.cbor.hex
```

The CBOR bytes match today's golden output exactly. (Covered automatically
by `SwapGoldenSpec` if it exists; otherwise verify via `cmp` against a
recorded reference.)
