# Building a disburse transaction

`disburse-wizard` resolves treasury state into a unified disburse
`intent.json`, and `tx-build` turns that intent into unsigned Conway
CBOR. The wizard supports both ADA and USDM; when `--unit` is omitted,
it defaults to USDM. The source scope drives the operation: a normal
scope disburses to a single beneficiary address, while `--scope
contingency` disburses ADA to one or more destination treasury scopes
(see [Contingency disburses](#contingency-disburses)).

See [Wizard input control](wizard-input-control.md) for the
`--exclude-utxo` / `--extra-tx-in` flags shared with every other
wizard.

## Wizard pipeline

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket

amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    disburse-wizard \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --beneficiary-addr addr1qvendor... \
        --amount 100000000 \
        --validity-hours 6 \
        --description "Settle March vendor invoice" \
        --justification "Approved network-compliance budget line" \
        --destination-label "Vendor Ltd." \
        --log disburse-wizard.log \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
            --log disburse-build.log \
            --out disburse.cbor.hex
```

The example above pays `100000000` smallest USDM units, or 100 USDM.
To pay ADA instead, add `--unit ada` and pass lovelace in `--amount`:

```bash
amaru-treasury-tx ... disburse-wizard \
    --unit ada \
    --amount 50000000 \
    ...
```

## On-chain references

Use `--reference-uri`, `--reference-type`, and `--reference-label`
when the rationale must carry the audit chain on chain. Each
`--reference-uri` opens a new reference slot; the following
`--reference-type` and `--reference-label` populate that slot until
the next URI. `--reference-type` defaults to `Other`, which matches
the d6c14625 mainnet precedent used by this repository's golden
fixture.

The Cyber Castellum Milestone 1 quickstart uses four IPFS references:

> **Node socket.** Use the `cardano-node-mainnet` container's own mount
> source, shown below. A dead socket file is still present at the old
> `/code/cardano-mainnet/ipc/node.socket`, so pointing at it fails with
> `Connection refused` — which reads like a node outage rather than a
> wrong path, and silently breaks `tx-validate` and `tx-inspect`.
> Confirm with
> `cardano-cli latest query tip --socket-path "$CARDANO_NODE_SOCKET_PATH" --mainnet`
> before a live run.

```bash
export CARDANO_NODE_SOCKET_PATH=/srv/prod-hot/cardano/mainnet/ipc/node.socket
RUNDIR=/tmp/attx-cyber-m1
mkdir -p "$RUNDIR"

amaru-treasury-tx --network mainnet disburse-wizard \
  --wallet-addr "$WALLET_ADDR" \
  --metadata "${DATA_DIR:-$HOME/.local/share/amaru-treasury}/metadata.json" \
  --scope network_compliance \
  --unit usdm \
  --amount 18750000000 \
  --beneficiary-addr addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl \
  --description "Cyber Castellum Whitehacking Milestone 1 - 18750 USDM" \
  --justification "Required to pay Cyber Castellum as vendor; payment instruction confirmed by CAG 2026-05-21" \
  --destination-label "Crypto Accounting Group off-ramp wallet" \
  --extra-signer core_development \
  --validity-hours 48 \
  --reference-uri ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da \
  --reference-label "Whitehacking Agreement - Cyber Castellum 2026-03-31" \
  --reference-uri ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu \
  --reference-label "Invoice 3508 - Cyber Castellum Whitehacking M1" \
  --reference-uri ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga \
  --reference-label "CAG MSA - 2026-04-09" \
  --reference-uri ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm \
  --reference-label "CAG payment confirmation - Laura Dugan email 2026-05-21" \
  --out "$RUNDIR/intent.json" \
  --log "$RUNDIR/wizard.log"
```

In `intent.json`, the references are written under
`rationale.references[]`:

```json
[
  {
    "uri": "ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da",
    "@type": "Other",
    "label": "Whitehacking Agreement - Cyber Castellum 2026-03-31"
  },
  {
    "uri": "ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu",
    "@type": "Other",
    "label": "Invoice 3508 - Cyber Castellum Whitehacking M1"
  }
]
```

During `tx-build`, IPFS URIs are emitted as `["ipfs://", "<CID>"]`
so each metadata string chunk stays under the Cardano ledger limit.
Labels containing the literal separator `" - "` are split the same
way as the d6c14625 transaction fixture, preserving compatibility
with downstream treasury metadata readers.

```asciinema-player
{
  "file": "assets/asciinema/disburse-wizard-references.cast"
}
```

## Rationale overrides

The rationale block written into the label-1694 metadata has two
fields the wizard fills in for you, and both can be overridden:

| Flag | Default | Use it when |
| --- | --- | --- |
| `--event` | `disburse` | the transaction belongs to a different event class in your treasury records |
| `--label` | `Disburse <unit>` | the default label is not what a co-signer or auditor should read |

Both are accepted by `disburse-wizard`, `swap-wizard` and
`withdraw-wizard`. They change only the recorded rationale — never the
transaction's value flow, signers, or validity.

```bash
  --event rebalance \
  --label "Treasury rebalance - USDM leg" \
```

## Pinning treasury inputs

By default the wizard selects treasury UTxOs itself, largest-first.
`--treasury-txin` (alias `--treasury-utxo`) restricts that selection to
outrefs you name, and is **repeatable**:

```bash
  --treasury-txin 57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519#8 \
  --treasury-txin 4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4#0 \
```

Use it when a specific UTxO must be consumed — to retire an awkward
small output, or to keep a particular UTxO untouched for a transaction
already in flight. If the named set cannot fund the disbursement the
build fails rather than quietly widening the selection.

This differs from `--exclude-utxo`, which removes candidates from the
default pool; see [wizard input control](wizard-input-control.md).

## What the wizard resolves

The wizard verifies the local `metadata.json` hint against the
on-chain registry, then resolves:

- the selected scope's treasury address, script hash, owner keyhashes,
  deployed scripts, and permissions reward account;
- wallet UTxOs for fuel and collateral;
- treasury UTxOs for the selected unit;
- current tip and validity upper bound;
- USDM policy and asset name constants.

For USDM, treasury UTxOs are selected largest-first by USDM quantity
until both the requested USDM amount and the beneficiary ADA deposit
are covered. The beneficiary output receives the requested USDM plus
the required lovelace. The treasury leftover output receives leftover
lovelace, leftover USDM, and any other non-USDM assets preserved from
the selected treasury inputs.

## Contingency disburses

Disburse ADA from the `contingency` treasury to other scope treasuries
by selecting `contingency` as the **source scope** — there is no
separate command or operation. `disburse-wizard --scope contingency` is
intentionally narrower than a normal-scope disburse:

- the source is always `contingency`;
- the unit is always ADA;
- destinations are selected by scope — repeat `--to <scope>:<ada>`, so a
  single transaction can pay several scopes at once — not by pasting a
  beneficiary address;
- each destination scope must be one of:
  `core_development`, `ops_and_use_cases`, `network_compliance`, or
  `middleware`. `contingency` itself is rejected as a destination.

A normal-scope disburse uses `--beneficiary-addr` / `--amount`;
`--scope contingency` rejects those and requires at least one `--to`
(and vice versa — `--to` is only valid with `--scope contingency`).

The `contingency` treasury has no owner key of its own, so the command
emits all four owned scope owners as required signers
(`core_development`, `ops_and_use_cases`, `network_compliance`,
`middleware`).

For example, to redistribute the contingency treasury across three
scopes in a single transaction, pinning a funding-rationale document on
chain:

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    disburse-wizard \
        --scope contingency \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
        --to core_development:1556478.04 \
        --to ops_and_use_cases:1397011.20 \
        --to network_compliance:898203.59 \
        --description "Contingency redistribution across scopes" \
        --justification "Approved by scope owners" \
        --reference-uri ipfs://bafkrei... --reference-label "Funding rationale" \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
        tx-build
```

`--to <scope>:<ada>` accepts an ADA decimal (up to 6 places) and
converts it to lovelace. Each destination scope receives its **exact**
authored amount; the transaction fee is taken from the wallet change,
never skimmed off a scope output. The command emits the unified
`disburse` intent shape consumed by `tx-build`.

## Existing intent

If an intent has already been reviewed, build it directly:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent disburse.intent.json \
    --out disburse.cbor.hex \
    --log disburse.log
```

The intent's top-level `network` field is the source of truth.
`tx-build` probes the socket against that network before querying
UTxOs or balancing.

## Payload shape

The shipped disburse branch supports ADA and USDM disburse intents:

```json
{
    "schema": 1,
    "action": "disburse",
    "network": "mainnet",
    "disburse": {
        "unit": "usdm",
        "amount": 100000000,
        "beneficiaryAddress": "addr1...",
        "usdmPolicy": "c48cbb3d...",
        "usdmToken": "0014df105553444d"
    }
}
```

The full intent also carries the shared `wallet`, `scope`,
`signers`, `validityUpperBoundSlot`, and `rationale` blocks
described by `docs/assets/intent-schema.json`.

## Validation

The build path queries a live `ChainContext`, builds the transaction,
aligns the fee with the bash/cardano-cli oracle behaviour, and
re-runs the evaluator against the final body. A successful log ends
with:

```text
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> disburse.cbor.hex
tx-build: VALIDATION OK
```

## Golden and regression evidence

`test/fixtures/disburse/ada/` pins the ADA disburse
bash/cardano-cli oracle:

- `body.cbor` is the expected body hex;
- `bash.oracle.tx.json` is the original cardano-cli JSON wrapper;
- `pparams.json`, `utxos.json`, and `exunits.json` freeze the
  chain context used to rebuild it offline.

The golden suite asserts both `body.cbor ==
bash.oracle.tx.json.cborHex` and `runFromIntent` against the
frozen fixture rebuilds that same oracle byte-for-byte.

USDM coverage is structural: unit tests assert intent translation,
beneficiary and treasury leftover values, treasury UTxO selection
until the beneficiary ADA deposit is covered, and beneficiary network
mismatch rejection.
