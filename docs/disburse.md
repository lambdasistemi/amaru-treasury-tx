# Building a disburse transaction

`disburse-wizard` resolves treasury state into a unified disburse
`intent.json`, and `tx-build` turns that intent into unsigned Conway
CBOR. The wizard supports both ADA and USDM; when `--unit` is omitted,
it defaults to USDM. The same shape applies to
`contingency-disburse-wizard`.

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

```bash
export CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket
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

Use `contingency-disburse-wizard` when ADA must move from the `contingency`
treasury to another scope treasury. This is intentionally narrower
than `disburse-wizard`:

- the source is always `contingency`;
- the unit is always ADA;
- the destination is selected by scope, not by manually pasting an
  address;
- the destination scope must be one of:
  `core_development`, `ops_and_use_cases`, `network_compliance`, or
  `middleware`.

The `contingency` treasury has no owner key of its own. The command
therefore emits all four owned scope owners as required signers:

- `core_development`
- `ops_and_use_cases`
- `network_compliance`
- `middleware`

For example, to top up Network Compliance with 200,000 ADA:

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    contingency-disburse-wizard \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
        --destination-scope network_compliance \
        --ada 200000 \
        --description "Contingency disburse for Network Compliance" \
        --justification "Treasury reallocation approved by scope owners" \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
        tx-build
```

`--ada` accepts an ADA decimal and converts it to lovelace in the
emitted intent. The command still emits the unified `disburse` intent
shape consumed by `tx-build`, but the public CLI surface enforces the
contingency disburse policy above.

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
