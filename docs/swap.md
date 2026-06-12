# Building a swap transaction

Walks through using `amaru-treasury-tx tx-build` to produce an
unsigned swap CBOR for a treasury scope, and the parity
guarantees behind it.

See [Wizard input control](wizard-input-control.md) for the
`--exclude-utxo` / `--extra-tx-in` flags shared with every other
wizard.

## What "swap" means

A swap tx spends N treasury UTxOs and emits:

- one **SundaeSwap order output** per chunk (with an inline datum
  describing the order), and
- one **leftover treasury output** holding what's not being swapped.

It also withdraws zero from the Amaru permissions reward account,
which is how the contract enforces M-of-N scope-owner approval.

The transaction shape follows
[`pragma-org/amaru-treasury/journal/2026/bin/swap.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/swap.sh)
for redeemers and output ordering. New Haskell-built order datums use
the current Amaru cancel-owner policy: `AtLeast 2
[core_development, ops_and_use_cases, network_compliance, middleware]`.

## Cancelling a pending order

`swap-cancel` builds an unsigned cancellation transaction for one
pending SundaeSwap V3 order that has already been identified. Until
the pending-order discovery report from issue #109 is available, pass
the order UTxO explicitly:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-cancel \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --wallet-txin "$WALLET_TXIN" \
    --order-txin "$ORDER_TXIN" \
    --validity-hours 28 \
    --out cancel.cbor.hex \
    --report cancel.report.json
```

The command verifies `metadata.json` against the chain, reads the
order UTxO's inline datum, uses the built-in mainnet Sundae order
reference script unless `--order-script-ref` is explicitly supplied,
and fails before writing CBOR unless:

- the order owner is a supported Amaru policy: legacy `AllOf` all four
  owners or current `AtLeast 2` all four owners,
- the owner key hashes match the verified Amaru treasury owners, and
- the order destination payment credential is the selected treasury
  script hash.

On non-mainnet networks, pass `--order-script-ref TXHASH#IX`
explicitly because the mainnet deployment constant does not apply.

The cancellation spends wallet fuel for fees and collateral, spends
the order with the SundaeSwap `Cancel` redeemer (`Constr 1 []`), and
returns the full order value to the selected treasury address. The
optional JSON report names the cancelled order, returned value,
treasury destination, required signers, fee, and next steps.

After fee alignment, `swap-cancel` runs the final unsigned transaction
through tx-tools phase-1 validation against the sampled N2C
`ChainContext`. Missing vkey witnesses are expected before signing and
are ignored; structural ledger failures such as missing inputs, value
non-conservation, or script-integrity mismatches abort before CBOR is
written.

The required signatures come from the order datum, not from a CLI
override. For the Amaru-generated orders built by this tool today,
that means at least two of the four treasury owner keys encoded in the
order owner policy: `core_development`, `ops_and_use_cases`,
`network_compliance`, and `middleware`.

Pass `--cancel-signer` more than once to choose the witness set for an
`AtLeast` order. If omitted, `swap-cancel` conservatively lists every
candidate owner from the order datum as a required signer.

## Operator-supplied rate workflow

`swap-wizard` is the "I have a rate, build the intent" command. It
does no outbound HTTP. Pass either a pre-validated `--min-rate` or an
`--ada-usdm` quote with an explicit `--slippage-bps`; then pipe the
intent into `tx-build --report -` and the envelope into
`report-render`:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr addr1q... \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --usdm 100000 \
    --split 33 \
    --ada-usdm 0.270 \
    --slippage-bps 100 \
    --validity-hours 28 \
    --description "Swapping ADA for \$100k against an operator-supplied ADA/USDM" \
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

Use `--min-rate DECIMAL` (already post-slippage) for the expert path
that bypasses slippage application entirely. Live ADA/USDM quote
retrieval is owned by the separate `swap-quote` command — see its
section below.

If the selected treasury cannot fund the derived ADA amount plus
per-chunk overhead, the wizard exits before emitting an intent. The
operator wallet is only preflighted for fee/change slack; it does not
fund the order min-UTxO or Sundae per-order fee.

## Swap the remaining pure ADA in a treasury scope

Use `--all-ada` when the selected scope has a pure ADA treasury UTxO
and the goal is to convert the maximum ledger-valid ADA amount to
USDM. This mode is mutually exclusive with `--usdm`, requires
`--split`, and rejects `--chunk-usdm` because the USDM target is
derived after the ADA amount is known.

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr "$WALLET_ADDR" \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --all-ada \
    --split 1 \
    --ada-usdm 0.265 \
    --slippage-bps 100 \
    --validity-hours 28 \
    --description "Swap remaining ADA to USDM" \
    --justification "Convert remaining treasury ADA balance" \
    --destination-label "Network Compliance's treasury" \
    --extra-signer ops_and_use_cases \
| amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  tx-build --out /dev/null --report - \
| amaru-treasury-tx report-render --metadata metadata-mainnet.json
```

All-ADA mode intentionally selects pure ADA treasury UTxOs only. If
the selected scope also has USDM-bearing or other token-bearing UTxOs,
those deposits are ignored by this mode so the swap intent does not
need to preserve native assets on the leftover output. The
`swap-wizard:` trace logs the selected pure ADA UTxOs, available
lovelace, computed ADA amount, implied USDM target, treasury leftover,
split/chunk count, per-chunk overhead, and effective minimum rate.

## Recommended quote-derived workflow (swap-quote)

`swap-quote` is the end-to-end command for a live, quote-derived swap
run. It fetches the live ADA/USDM rate, runs affordability before
emitting CBOR, and writes the full audit (`params.json`) to the
output directory:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-quote \
    --wallet-addr addr1q... \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --usdm 100000 \
    --split 33 \
    --price-source coingecko-ada-usdm \
    --slippage-bps 100 \
    --validity-hours 28 \
    --description "Swapping ADA for \$100k using a live ADA/USDM quote" \
    --justification "Required to pay Antithesis as vendor" \
    --destination-label "Network Compliance's treasury" \
    --extra-signer core_development \
    --out-dir swap-run-$(date -u +%Y-%m-%d)
```

The derived rate is computed as `(ADA/USD) / (USDM/USD)` from two
CoinGecko `simple/price` calls (`ids=cardano` and `ids=usdm-2`). Both
upstream observations are captured under
`quote.provenance.components` in the run's `params.json`, so the
audit trail reconstructs the derived value from raw inputs. Each
fetch is preceded by the trust-anchor stderr line (see below).

A live smoke script is shipped at
`scripts/smoke/swap-quote-live-usdm.sh`. It runs `swap-quote` against
the configured live node and Internet, then re-derives the rate from
the recorded components to prove the composition. It is **not** part
of `just ci` — the CoinGecko public API rate-limits aggressively, so
the smoke is operator-invoked.

### TLS trust anchor

Live quote sources used by the separate `swap-quote` command make
outbound HTTPS requests. The released AppImage, DEB, and RPM artifacts
wrap the executable with a `makeWrapper` shim that `--set-default`s
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

If an owner key is imported into an age vault, `witness` can produce the
same raw witness artifact without passing a plaintext `*.skey` file to
the signing command:

Run `vault create` during the key import ceremony. Humans should use
`--signing-key-paste`; the pasted signing-key material is hidden while
the CLI reads it. The accepted human input is either a full
`cardano-cli` `.skey` JSON envelope or one `cardano-addresses`
`addr_xsk1...` address extended signing key line. Normal signing then
uses only the encrypted vault plus the passphrase. After verifying and
backing up the encrypted vault, clear the clipboard or source buffer
under your custody policy.

```bash
amaru-treasury-tx --network mainnet vault create \
  --signing-key-paste \
  --label core_development \
  --out treasury.vault.age

# Paste either the full cardano-cli .skey JSON or the addr_xsk1... line.
# The pasted bytes are hidden.
```

The `addr_xsk1...` value is the address-level extended signing key line
used for payment signing. It is not a root or account private key.

For automation, stream the signing key from a secret manager and pass the
vault passphrase through an inherited file descriptor:

```bash
exec 9<<<"$VAULT_PASSPHRASE"

secret-manager-read core-development-payment-skey \
| amaru-treasury-tx --network mainnet vault create \
  --signing-key-stdin \
  --label core_development \
  --out treasury.vault.age \
  --vault-passphrase-fd 9

exec 9<&-
exec 9<<<"$VAULT_PASSPHRASE"
```

```bash
amaru-treasury-tx --network mainnet witness \
  --tx unsigned.cbor.hex \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  --out core_development.witness.hex

exec 9<&-
```

`witness --tx` accepts either raw unsigned CBOR hex or a `cardano-cli`
`Tx ConwayEra` JSON envelope. If the body came from `cardano-cli`, store
the full JSON in a file and pass that file directly to `witness`.
Interactive paste into `de-envelope` is fragile because any real newline
inside the long `cborHex` JSON string makes the JSON invalid.

```bash
jq -e . cli.tx.body.json >/dev/null
test "$(jq -r .cborHex cli.tx.body.json | wc -l | tr -d ' ')" = 1

exec 9<<<"$VAULT_PASSPHRASE"

amaru-treasury-tx --network mainnet witness \
  --tx cli.tx.body.json \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  --out core_development.witness.hex

exec 9<&-
```

Unwrap that same envelope only when moving back to raw-hex commands:

```bash
amaru-treasury-tx de-envelope < cli.tx.body.json > unsigned.cbor.hex
```

Use `tr -d '\n' < core_development.witness.hex` when passing the file
contents to `attach-witness`. If the transaction body does not declare
required signer hashes, include `--expected-key-hash HASH` or
`--allow-unlisted-key`.

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

## Composing with cardano-cli

`tx-build`, `attach-witness`, and `submit` remain raw-CBOR-hex
commands. Use the envelope filters only at the boundary where a
`cardano-cli` JSON text envelope is needed:

| Filter | Direction |
|---|---|
| `envelope-tx` | raw unsigned transaction hex -> `Tx ConwayEra` JSON |
| `envelope-witness` | raw witness hex -> `TxWitness ConwayEra` JSON |
| `envelope-signed-tx` | raw signed transaction hex -> `Tx ConwayEra` JSON |
| `de-envelope` | any Conway envelope JSON -> raw `cborHex` |

`de-envelope` parses complete JSON from stdin and writes the extracted
`cborHex` plus one trailing newline. It does not unwrap terminal
transcripts or repair line-broken strings. If a long transaction body
arrives through a clipboard or chat UI, write it to a file first and
validate it:

```bash
jq -e . cli.tx.body.json >/dev/null
test "$(jq -r .cborHex cli.tx.body.json | wc -l | tr -d ' ')" = 1
```

Visual wrapping in a terminal is harmless. A real newline inside the
quoted `cborHex` value is different data and is rejected by JSON
parsing.

To hand an Amaru-built transaction body to `cardano-cli` for assembly or
submission, wrap the raw `tx-build` output. Prefer the Amaru vault flow
for the signing step, then wrap the produced witness when a
`cardano-cli` JSON witness is needed:

```bash
amaru-treasury-tx tx-build \
  --out unsigned.cbor.hex \
  --report swap.report.json \
  < intent.json

amaru-treasury-tx envelope-tx \
  < unsigned.cbor.hex \
  > swap.tx.body.json

exec 9<<<"$VAULT_PASSPHRASE"

amaru-treasury-tx --network mainnet witness \
  --tx unsigned.cbor.hex \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
| amaru-treasury-tx envelope-witness \
> owner.witness.json

exec 9<&-
```

If a separate signer or legacy process already returns a `cardano-cli`
witness envelope, bring that witness back into the Amaru raw-hex
pipeline by extracting its `cborHex` and passing the value to
`attach-witness`:

```bash
owner_witness_hex="$(
  amaru-treasury-tx de-envelope < owner.witness.json | tr -d '\n'
)"

amaru-treasury-tx attach-witness \
  --tx unsigned.cbor.hex \
  --witness "$owner_witness_hex" \
  --out signed.cbor.hex
```

A full Amaru-to-`cardano-cli` round trip keeps the shape changes at the
pipeline ends and still signs through the encrypted vault:

```bash
amaru-treasury-tx tx-build \
  --out unsigned.cbor.hex \
  --report swap.report.json \
  < intent.json

amaru-treasury-tx envelope-tx \
  < unsigned.cbor.hex \
  > swap.tx.body.json

exec 9<<<"$VAULT_PASSPHRASE"

amaru-treasury-tx --network mainnet witness \
  --tx unsigned.cbor.hex \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
| amaru-treasury-tx envelope-witness \
> owner.witness.json

exec 9<&-

cardano-cli conway transaction assemble \
  --tx-body-file swap.tx.body.json \
  --witness-file owner.witness.json \
  --out-file swap.signed.tx.json

cardano-cli conway transaction submit \
  --tx-file swap.signed.tx.json \
  --mainnet
```

A `cardano-cli`-to-Amaru-to-`cardano-cli` path is symmetric: unwrap the
incoming `cardano-cli` transaction body, use the raw `attach-witness`
contract, then wrap the signed result again:

```bash
owner_witness_hex="$(
  amaru-treasury-tx de-envelope < owner.witness.json | tr -d '\n'
)"

amaru-treasury-tx de-envelope < cli.tx.body.json \
| amaru-treasury-tx attach-witness --witness "$owner_witness_hex" \
| amaru-treasury-tx envelope-signed-tx \
> cli-compatible.signed.tx.json
```

`de-envelope` rejects non-Conway envelopes before they reach the raw
commands. A stale Babbage body fails with the offending era in stderr:

```text
de-envelope: unsupported cardano-cli envelope era in type `Tx BabbageEra`; expected ConwayEra
```

Raw hex is not an envelope. Piping raw hex into `de-envelope` fails
without writing stdout:

```text
de-envelope: expected a cardano-cli JSON envelope object starting with `{`; first non-whitespace byte was 0x64
```

The `envelope-*` commands are deliberately dumb wrappers: they trim
trailing ASCII whitespace from stdin and place the remaining bytes in
`cborHex`. They do not validate whether the bytes are valid CBOR; the
consumer (`cardano-cli`, `attach-witness`, or `submit`) remains
responsible for semantic transaction validation.

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
| `result.report.walletAccounting.changeOutput.value.lovelace` | 50,006,215,897 |
| `result.report.walletAccounting.collateralReturn.value.lovelace` | 50,005,704,207 |
| `result.report.walletAccounting.feeLovelace` | 1,023,379 |
| `result.report.walletAccounting.netSpendLovelace` | 1,023,379 |
| `result.report.treasuryAccounting.inputTotal.lovelace` | 1,450,000,000,000 |
| `result.report.treasuryAccounting.sundaeOrderTotal.lovelace` | 408,271,505,306 |
| `result.report.treasuryAccounting.perChunkOverheadLovelace` | 3,280,000 |
| `result.report.treasuryAccounting.treasuryLeftover.lovelace` | 1,041,728,494,694 |
| `result.report.treasuryAccounting.netDebit.lovelace` | 408,271,505,306 |
| `result.report.validation.feeLovelace` | 1,023,379 |
| `result.report.validation.bodySizeBytes` | 14,987 |
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

The checked-in swap fixture pins the current Haskell-built transaction
body, including the `AtLeast 2` cancel-owner datum policy:

| Field | Haskell fixture |
|---|---|
| total bytes | 14987 |
| fee | 1,041,155 |
| total_collateral | 1,561,733 |

The test checks two things: `test/fixtures/swap/expected.cbor` must
equal `test/fixtures/swap/target.tx.json.cborHex`, and `runFromIntent`
against the frozen `ChainContext` must rebuild that same hex. The
historical bash oracle is no longer byte-identical until the bash
recipe adopts the same cancel-owner datum policy. See
[Parity report](parity.md) for the provenance.

## See also

- [ChainContext](chain-context.md) — the data type both modes consume.
- [Architecture](architecture.md) — module layout overview.
