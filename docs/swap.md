# Building a swap transaction

Walks through using `amaru-treasury-tx swap` to produce an unsigned
swap CBOR for a treasury scope, and the parity guarantees behind it.

## What "swap" means

A swap tx spends N treasury UTxOs and emits:

- one **SundaeSwap order output** per chunk (with an inline datum
  describing the order), and
- one **leftover treasury output** holding what's not being swapped.

It also withdraws zero from the Amaru permissions reward account,
which is how the contract enforces M-of-N scope-owner approval.

The shape mirrors
[`pragma-org/amaru-treasury/journal/2026/bin/swap.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/swap.sh)
exactly — same redeemers, same datums, same output ordering.

## CLI usage

The recommended path is to pipe the wizard's output straight in
(see [Quickstart §4](quickstart.md#4-the-famous-swap-end-to-end)
for the full pipe). For an `intent.json` you already have on
disk:

```bash
amaru-treasury-tx \
  --node-socket /path/to/cardano-node.socket \
  swap \
    --intent path/to/intent.json \
    --out swap.cbor.hex \
    --log swap.log
```

Or read socket from `$CARDANO_NODE_SOCKET_PATH`, intent from
stdin, CBOR to stdout, trace to stderr:

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
amaru-treasury-tx swap < intent.json > swap.cbor.hex
```

Every value-affecting step emits one `swap:` line through the
typed
[`SwapEvent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Swap/Trace.hs)
tracer. `--log PATH` redirects them to a file (default = stderr).

## What the CLI does

1. Reads `intent.json`.
2. Translates it to the typed `SwapIntent` + rationale `Metadatum`.
3. Builds a `liveContext` by querying the node for every `TxIn` the
   build will reference (wallet, treasury inputs, the four reference
   inputs for scripts and registry).
4. Runs `runSwapBuild`:
   - `Cardano.Node.Client.TxBuild.build` with the live evaluator,
   - post-patches `total_collateral` + `collateral_return`
     ([upstream #124](https://github.com/lambdasistemi/cardano-node-clients/issues/124)),
   - re-evaluates every redeemer against the final patched tx and
     reports script outcomes.
5. Writes hex CBOR to stdout / `--out`. Exits non‑zero if any
   redeemer failed validation.

## intent.json schema

Top-level shape:

```json
{
  "wallet":   { "txIn": "<txid>#<ix>", "address": "addr1q…" },
  "scope":    { … addresses, deployed-at refs, registry policy id … },
  "swap":     { … chunk size, amount, rate, sundae fee, USDM unit … },
  "signers":  ["<keyhash hex>", "<keyhash hex>"],
  "validityUpperBoundSlot": 186364542,
  "rationale": {
    "description":      "Swapping ADA for $X at rate Y",
    "destinationLabel": "<scope>'s treasury",
    "justification":    "<copy>"
  }
}
```

See `specs/001-treasury-tx-cli/contracts/cli.md` for the full spec
of every field. Every hash is a 28-byte hex string; every TxIn is
`<32-byte hex>#<ix>`; bech32 base addresses for `wallet.address`,
`scope.treasuryAddress`, and `swap.swapOrderAddress`.

## Validation

Once the build returns, the CLI re-runs the live evaluator against
the final patched tx. This proves:

- Every redeemer datum is well-formed and committed.
- Every redeemer's `ExUnits` are sufficient to run its script.
- The integrity hash matches the redeemer set the chain would see.

This is the strongest validation possible without signatures.

## Parity status

The Haskell stack reproduces an on-chain swap tx
([`/code/swap-experiment/user-final.hex`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/001-treasury-tx-cli/contracts/cli.md))
to the byte, except for an 8-byte numeric residue in the fee chain:

| Field | Haskell | bash via cardano-cli | Δ |
|---|---|---|---|
| total bytes | 14954 | 14954 | 0 |
| fee | 1,009,695 | 1,043,795 | −34,100 |
| total_collateral | 1,514,543 | 1,565,693 | −51,150 |
| collateral_return | wallet−1,514,543 | wallet−1,565,693 | +51,150 |
| change | input−fee−sundae | input−fee−sundae | +34,100 |
| script_data_hash | identical | identical | 0 |
| aux_data_hash | identical | identical | 0 |

The 34,100‑lovelace residue is the `cardano-node-clients` vs
`cardano-cli` fee-estimator gap. About 3,344 of those are size-driven
(`build` doesn't yet count the `total_collateral` / `collateral_return`
bytes — see upstream
[#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124));
the rest is the same tail-of-iteration over-shoot we saw bash-vs-bash.

## See also

- [ChainContext](chain-context.md) — the data type both modes consume.
- [Architecture](architecture.md) — module layout overview.
