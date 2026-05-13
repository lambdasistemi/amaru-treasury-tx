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

## Recommended quote-derived workflow

Use `swap-wizard` for operator swap preparation. It owns the
chain-anchored resolver and emits the unified intent to stdout. For a
quote-derived run, pass a quote source or explicit quote plus
`--slippage-bps`; then pipe the intent into `tx-build --report -` and
pipe the build-output envelope into `report-render`:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr addr1q... \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --usdm 100000 \
    --split 33 \
    --price-source coingecko-ada-usd \
    --slippage-bps 100 \
    --validity-hours 28 \
    --description "Swapping ADA for $100k using a fresh ADA/USD quote" \
    --justification "Required to pay Antithesis as vendor" \
    --destination-label "Network Compliance's treasury" \
    --extra-signer core_development \
| amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  tx-build --out /dev/null --report - \
| amaru-treasury-tx \
  report-render --metadata metadata-mainnet.json
```

The middle command emits `{ intent, result }`. On success,
`result.tx-cbor` is the unsigned Conway transaction and
`result.report` is the mechanical report used by the renderer.
On an expected build failure, `result.failure.code` and
`result.failure.message` carry the normalized tx-build diagnostic and
no `tx-cbor` or nested report is present.

Use `--ada-usd DECIMAL` for an explicit ADA/USD override when the
operator has already captured a fresh quote. Use `--ada-usdm DECIMAL`
for an explicit ADA/USDM override. Named live ADA/USDM sources are
deferred until a provider contract is approved; use explicit
`--ada-usdm` in the meantime.

If the selected treasury cannot fund the derived ADA amount plus
per-chunk overhead, the wizard exits before emitting an intent. The
operator wallet is only preflighted for fee/change slack; it does not
fund the order min-UTxO or Sundae per-order fee.

### TLS trust anchor

Live quote sources (`--price-source coingecko-ada-usd`) make an outbound
HTTPS request. The released AppImage, DEB, and RPM artifacts wrap the
executable with a `makeWrapper` shim that `--set-default`s
`SSL_CERT_FILE` and `SYSTEM_CERTIFICATE_PATH` to a Mozilla NSS CA bundle
that lives inside the artifact's Nix closure. This makes live quotes
work on hosts whose `/etc/ssl/certs` layout the bundled Haskell
`tls`/`x509-system` cannot read directly — most notably NixOS, but also
minimal Docker images that have no CA bundle of their own installed.

Each live quote fetch logs the active trust anchor to stderr before
opening the TLS handshake:

```text
swap-quote: TLS trust anchor SSL_CERT_FILE=... SYSTEM_CERTIFICATE_PATH=...
```

If the operator wants the binary to use the host's own CA store, export
either env before invoking `swap-wizard`:

```bash
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
```

The wrapper uses `--set-default`, so any operator-exported value wins
and the stderr line shows that override took effect. The bundled
fallback is frozen at release time; operators who need a fresher trust
store should either override the env or upgrade to a newer release.

## Sign and submit

Once `tx-build` has emitted the unsigned CBOR hex, attach detached
vkey witnesses with `attach-witness` and push the result to chain
with `submit`. Both commands read raw CBOR hex from stdin (or a
`--tx PATH`) and emit raw CBOR hex to stdout (or `--out PATH`), so
the full pipeline is one pipe per stage with no JSON envelopes and
no `cardano-cli` dependency:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard ... \
| amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  tx-build --out - --report swap.report.json \
| amaru-treasury-tx attach-witness \
    --witness 8200825820...5840... \
    --witness 8200825820...5840... \
| amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  submit
```

The two `--witness` arguments are the detached vkey witnesses your
external signer (HSM, hardware wallet, key-only ceremony) hands back
— each is a CBOR-hex `WitVKey 'Witness` payload of the form
`8200825820<vkey32>5840<sig64>`. Repeat the flag once per signer. The
swap is gated by the scope-owner approval rule on chain, so attach at
least one owner witness plus any extra signers the wizard required.

On success, `submit` prints the accepted tx hash to stdout and a
`submit: accepted <txId>` line to stderr. On rejection, it prints the
rejection reason from the node to stderr and exits non-zero.

You can save the intermediate signed CBOR if you want to inspect it
before submission:

```bash
amaru-treasury-tx tx-build --out unsigned.cbor.hex --report swap.report.json < intent.json
amaru-treasury-tx attach-witness \
  --tx unsigned.cbor.hex \
  --witness 8200825820...5840... \
  --witness 8200825820...5840... \
  --out signed.cbor.hex
amaru-treasury-tx --network mainnet submit --tx signed.cbor.hex
```

## Expert/manual override

Direct `swap-wizard --min-rate` remains available for expert use with
precomputed rates. That manual override path does not fetch a quote and
does not require a slippage policy. Operators using it must keep the
external quote, slippage policy, and rate arithmetic separately.

## CLI usage

For an `intent.json` you already have on disk, use `tx-build`
directly:

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
[`BuildEvent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Build/Trace.hs)
tracer. `--log PATH` redirects them to a file (default = stderr).
`--report PATH` writes the deterministic build-output envelope. On
success, that envelope contains the transaction CBOR and mechanical
report. On expected build or validation failure, it contains
`result.failure.code` and `result.failure.message`. If the requested
report cannot be written, `tx-build` exits non-zero and names the
failed path in the trace.
To render the Markdown review manually, run:

```bash
amaru-treasury-tx report-render \
  --in swap.report.json \
  --out swap.report.md \
  --metadata metadata-mainnet.json
```

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
5. Runs `Amaru.Treasury.Build.runSwap`:
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
writes `swap.cbor.hex`, then render `swap.report.md` and inspect the
Markdown before signing. The JSON is a build-output envelope using the
public schema in `docs/assets/tx-report-schema.json`: top-level
`intent` plus top-level `result`. For successful builds,
`result.tx-cbor` contains the unsigned transaction bytes and
`result.report` contains the mechanical report facts below.

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

The frozen swap fixture envelope at
`test/fixtures/swap/report.golden.json` currently records these nested
`result.report` facts:

| Report field | Fixture value |
|---|---:|
| `result.report.walletAccounting.inputs[0].value.lovelace` | 50,007,239,276 |
| `result.report.walletAccounting.changeOutput.value.lovelace` | 50,006,199,573 |
| `result.report.walletAccounting.collateralReturn.value.lovelace` | 50,005,679,721 |
| `result.report.walletAccounting.feeLovelace` | 1,039,703 |
| `result.report.walletAccounting.netSpendLovelace` | 1,039,703 |
| `result.report.treasuryAccounting.inputTotal.lovelace` | 1,450,000,000,000 |
| `result.report.treasuryAccounting.sundaeOrderTotal.lovelace` | 408,271,505,306 |
| `result.report.treasuryAccounting.perChunkOverheadLovelace` | 3,280,000 |
| `result.report.treasuryAccounting.treasuryLeftover.lovelace` | 1,041,728,494,694 |
| `result.report.treasuryAccounting.netDebit.lovelace` | 408,271,505,306 |
| `result.report.validation.feeLovelace` | 1,039,703 |
| `result.report.validation.bodySizeBytes` | 14,954 |
| `result.report.validation.socketNetworkMagic` | 764,824,073 |
| `result.report.validation.redeemerCount` | 2 |
| `result.report.validation.redeemerFailures` | 0 |

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

Validation review should confirm
`result.report.validation.validationStatus` is `ok`,
`result.report.validation.networkMatches` is `true`, and
`result.report.validation.validityInterval.invalidHereafter` is
`186796799`. The metadata summary records CIP-1694 label presence and
auxiliary data hash
`1163dfe0f06e30a30353b706b988721fb0a6f5168db22402ef6a76b8e677868d`.

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
