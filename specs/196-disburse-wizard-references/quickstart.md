# Quickstart: build a vendor disburse with on-chain IPFS references

**Phase**: 1 (design & contracts)
**Operator target**: build the unsigned Cyber Castellum Whitehacking
Milestone 1 disburse tx (18,750 USDM, `network_compliance` scope) with
all four supporting documents pinned in the on-chain rationale.

## Prerequisites

- `amaru-treasury-tx` ≥ the version bumped in slice S5 (see
  `CHANGELOG.md`).
- A running Cardano mainnet node with N2C socket at
  `$CARDANO_NODE_SOCKET_PATH` (e.g.
  `/code/cardano-mainnet/ipc/node.socket`).
- Local checkout of the journal metadata, or the file pinned to
  `${DATA_DIR:-$HOME/.local/share/amaru-treasury}/metadata.json`.
- The operator wallet bech32 (mainnet fuel + collateral).
- The IPFS CIDs for the four supporting documents (all pre-pinned on
  Pinata at the time of writing):

  | Document | CID |
  |---|---|
  | Whitehacking Agreement (signed contract) | `bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da` |
  | Invoice 3508 (April 2026 milestone 1) | `bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu` |
  | CAG Master Service Agreement | `bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga` |
  | CAG payment confirmation email (Laura Dugan, DKIM-signed) | `bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm` |

- The CAG off-ramp destination bech32:
  `addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`

## Step 1 — invoke the wizard

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

## Step 2 — build the unsigned tx

```bash
amaru-treasury-tx --network mainnet tx-build \
  --intent "$RUNDIR/intent.json" \
  --out "$RUNDIR/unsigned-tx.hex" \
  --report "$RUNDIR/report.json" \
  --log "$RUNDIR/build.log"

amaru-treasury-tx --network mainnet envelope-tx \
  --in "$RUNDIR/unsigned-tx.hex" \
  --out "$RUNDIR/unsigned-tx.tx"
```

## Step 3 — inspect

```bash
tx-inspect \
  --rules "${DATA_DIR:-$HOME/.local/share/amaru-treasury}/amaru-treasury.yaml" \
  "$RUNDIR/unsigned-tx.tx"
```

Expected: under aux data → label 1694 → body, the `references` list
shows **four** entries, each with the IPFS URI rendered as
`ipfs://<CID>` and the label rendered with the `" - "` split where
present. Cross-check the CIDs against the list above.

## Step 4 — validate (phase-1 pre-flight)

```bash
tx-validate \
  --input "$RUNDIR/unsigned-tx.hex" \
  --n2c-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network-magic 764824073 \
  --output human
```

Expected: clean validation. The known `WithdrawalsNotInRewardsCERTS`
false positive may appear (per the amaru-treasury-tx skill's
gotchas section) — verify via `cardano-cli query stake-address-info`
against the permissions stake credential before dismissing.

## Step 5 — collect witnesses, attach, submit

Follow the standard amaru-treasury-tx witness protocol (vault →
witness CBOR → attach-witness → submit). The on-chain rationale at
submission carries the same `references[]` shape proven in step 3.
This part is identical to every other multi-signer disburse and is
not specific to the references[] change.

## What to verify in the on-chain receipt

After submission and confirmation:

```bash
curl -fsS -H "project_id: $BLOCKFROST_MAINNET" \
  "https://cardano-mainnet.blockfrost.io/api/v0/txs/<txid>/metadata" \
  | jq '.[0].json_metadata.body.references'
```

Expected: a 4-element array with each entry containing
`uri: ["ipfs://", "<CID>"]`, `@type: "Other"`, and a `label` list
matching the input.
