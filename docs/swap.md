# Building a swap transaction

Walks through using `amaru-treasury-tx tx-build` to produce an
unsigned swap CBOR for a treasury scope, and the parity
guarantees behind it.

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
  tx-build \
    --intent path/to/intent.json \
    --out swap.cbor.hex \
    --log build.log \
    --report swap.report.json
```

Or read socket from `$CARDANO_NODE_SOCKET_PATH`, intent from
stdin, CBOR to stdout, trace to stderr:

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
amaru-treasury-tx tx-build < intent.json > swap.cbor.hex
```

Every value-affecting step emits one `tx-build:` line through
the typed
[`BuildEvent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/TreasuryBuild/Trace.hs)
tracer. `--log PATH` redirects them to a file (default = stderr).
`--report PATH` writes the deterministic JSON transaction report after
successful validation. If the requested report cannot be written,
`tx-build` exits non-zero and names the failed path in the trace.
The action and the network are read from the intent's top-level
`action` and `network` fields — there are no `--network` /
`--action` CLI flags on `tx-build` (single source of truth).

## What the CLI does

1. Reads the unified `intent.json` (any of the four actions);
   the parser returns a `SomeTreasuryIntent` carrying the
   action discriminator at the type level.
2. Probes the N2C handshake against the intent's declared
   `network`. On a magic mismatch, `tx-build` exits 6 with a
   typed event naming both networks before any chain query
   happens.
3. Translates the typed intent to its action-specific record
   (today: `SwapIntent` + rationale `Metadatum`).
4. Builds a `liveContext` by querying the node for every `TxIn`
   the build will reference (wallet, treasury inputs, the four
   reference inputs for scripts and registry).
5. Runs `Amaru.Treasury.TreasuryBuild.runSwap`:
   - `Cardano.Node.Client.TxBuild.build` with the live evaluator,
   - post-patches `total_collateral` + `collateral_return`
     ([upstream #124](https://github.com/lambdasistemi/cardano-node-clients/issues/124)),
   - aligns the final fee with `cardano-cli transaction build`'s
     default key-witness estimate,
   - re-evaluates every redeemer against the final patched tx and
     reports script outcomes.
6. Writes hex CBOR to stdout / `--out`. Exits non‑zero if any
   redeemer failed validation.

## Pre-signing report review

Generate `swap.report.json` with the same `tx-build` command that
writes `swap.cbor.hex`, then inspect the report before signing. The
report is mechanically generated from the successful build result and
uses the public schema in `docs/assets/tx-report-schema.json`.

Swap report review checklist:

- Wallet accounting separates wallet inputs, change, collateral input,
  collateral return, fee, and `netSpendLovelace`.
- Treasury accounting separates treasury inputs, Sundae order total,
  per-chunk overhead, treasury leftover, and `netDebit`.
- Output roles cover every final transaction output exactly once:
  `swapOrder`, `treasuryLeftover`, `walletChange`, or `unknown`.
- Signer entries show the required key hash and mechanical source,
  such as `selectedScopeOwner`, `extraSigner`, `intentRequiredSigner`,
  or `txBodyRequiredSigner`.
- Validation facts show the intent network, socket network magic,
  network match, fee, body size, redeemer count, redeemer failures,
  validation status, and validity interval.

The frozen swap fixture report at
`test/fixtures/swap/report.golden.json` currently records these facts:

| Report field | Fixture value |
|---|---:|
| `walletAccounting.inputs[0].value.lovelace` | 50,007,239,276 |
| `walletAccounting.changeOutput.value.lovelace` | 50,006,199,573 |
| `walletAccounting.collateralReturn.value.lovelace` | 50,005,679,721 |
| `walletAccounting.feeLovelace` | 1,039,703 |
| `walletAccounting.netSpendLovelace` | 1,039,703 |
| `treasuryAccounting.inputTotal.lovelace` | 1,450,000,000,000 |
| `treasuryAccounting.sundaeOrderTotal.lovelace` | 408,271,505,306 |
| `treasuryAccounting.perChunkOverheadLovelace` | 3,280,000 |
| `treasuryAccounting.treasuryLeftover.lovelace` | 1,041,728,494,694 |
| `treasuryAccounting.netDebit.lovelace` | 408,271,505,306 |
| `validation.feeLovelace` | 1,039,703 |
| `validation.bodySizeBytes` | 14,954 |
| `validation.socketNetworkMagic` | 764,824,073 |
| `validation.redeemerCount` | 2 |
| `validation.redeemerFailures` | 0 |

The same fixture has 35 produced outputs: 33 `swapOrder` outputs, one
`treasuryLeftover` output, and one `walletChange` output. The first 32
swap orders each carry 12,503,280,000 lovelace; the final order carries
8,166,545,306 lovelace. The treasury leftover output is at index 33,
and wallet change is at index 34.

Signer review for the fixture requires two witnesses:

| Source | Scope | Key hash |
|---|---|---|
| `selectedScopeOwner` | `network_compliance` | `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` |
| `extraSigner` | | `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` |

Validation review should confirm `validation.validationStatus` is
`ok`, `validation.networkMatches` is `true`, and
`validation.validityInterval.invalidHereafter` is `186796799`. The
metadata summary records CIP-1694 label presence and auxiliary data
hash `1163dfe0f06e30a30353b706b988721fb0a6f5168db22402ef6a76b8e677868d`.

## intent.json schema

Top-level shape (unified intent JSON, schema v1):

```json
{
  "schema":  1,
  "action":  "swap",
  "network": "mainnet",
  "wallet":   { "txIn": "<txid>#<ix>", "address": "addr1q…", "extraTxIns": [] },
  "scope":    { "id": "<scope name>", … addresses, deployed-at refs, registry policy id … },
  "swap":     { … chunk size, amount, rate, sundae fee, USDM unit … },
  "signers":  ["<keyhash hex>", "<keyhash hex>"],
  "validityUpperBoundSlot": 186796799,
  "rationale": {
    "event":            "disburse",
    "label":            "Swap ADA<->USDM",
    "description":      "Swapping ADA for $X at rate Y",
    "destinationLabel": "<scope>'s treasury",
    "justification":    "<copy>"
  }
}
```

See `specs/005-unified-tx-build/data-model.md` for the full
field-level contract and the four action variants. Every hash
is a 28-byte hex string; every TxIn is `<32-byte hex>#<ix>`;
bech32 base addresses for `wallet.address`,
`scope.treasuryAddress`, and `swap.swapOrderAddress`. The
`schema` field is gated against
`Amaru.Treasury.IntentJSON.allowedSchemas` — the bump protocol
documented there is the single source of truth.

`wallet.extraTxIns` is an optional array of additional pure-ADA
wallet UTxOs aggregated as fuel alongside `wallet.txIn`; absent or
empty means the head UTxO already covered the wallet target.

The machine-readable contract is committed at
`docs/assets/intent-schema.json`. It is generated from
`Amaru.Treasury.IntentJSON.Schema`; run `just update-schema`
after changing the intent shape. `just schema-check` and CI
diff the checked-in asset against the executable output. The
unit suite validates the tx-build swap fixture, the tx-build ADA
disburse fixture, and the wizard output against it.

## Validation

Once the build returns, the CLI re-runs the live evaluator against
the final patched tx. This proves:

- Every redeemer datum is well-formed and committed.
- Every redeemer's `ExUnits` are sufficient to run its script.
- The integrity hash matches the redeemer set the chain would see.

This is the strongest validation possible without signatures.

## Parity status

The Haskell stack reproduces a bash/cardano-cli mainnet swap
oracle byte-for-byte:

| Field | Haskell | bash via cardano-cli | Δ |
|---|---|---|---|
| total bytes | 14954 | 14954 | 0 |
| fee | 1,039,703 | 1,039,703 | 0 |
| total_collateral | 1,559,555 | 1,559,555 | 0 |
| collateral_return | identical | identical | 0 |
| change | identical | identical | 0 |
| script_data_hash | identical | identical | 0 |
| aux_data_hash | identical | identical | 0 |

The test checks two things: `test/fixtures/swap/expected.cbor`
must equal `test/fixtures/swap/bash.oracle.tx.json.cborHex`, and
`runFromIntent` against the frozen `ChainContext` must rebuild
that same hex. See [Parity report](parity.md) for the provenance.

## See also

- [ChainContext](chain-context.md) — the data type both modes consume.
- [Architecture](architecture.md) — module layout overview.
