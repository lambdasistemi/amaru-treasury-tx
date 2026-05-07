# Contract: `withdraw-wizard`

`withdraw-wizard` resolves a treasury reward withdrawal and emits
unified intent JSON. It never emits CBOR and never signs/submits.

## Usage

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network preprod \
  withdraw-wizard \
    --wallet-addr addr_test1... \
    --metadata metadata.json \
    --scope core_development \
    --validity-hours 6 \
    [--description TEXT] \
    [--justification TEXT] \
    [--destination-label TEXT] \
    [--event TEXT] \
    [--label TEXT] \
    [--out intent.json] \
    [--log wizard.log]
```

## Required flags

| Flag | Meaning |
|---|---|
| `--wallet-addr ADDR` | Wallet address used to select fuel/collateral. |
| `--metadata PATH` | Local upstream metadata file, verified against chain. |
| `--scope SCOPE` | Treasury scope. |
| `--validity-hours N` | Validity window from current tip. |

Global CLI flags provide `--network` / `--network-magic` and
`--node-socket`.

## Optional rationale flags

| Flag | Default |
|---|---|
| `--event TEXT` | `withdraw` |
| `--label TEXT` | `Withdraw treasury rewards` |
| `--description TEXT` | `Withdraw accumulated rewards for <scope>` |
| `--destination-label TEXT` | `<scope> treasury` |
| `--justification TEXT` | `Move rewards back under treasury contract control` |

## Output contract

Current implementation note: the CLI runner surface is present, but live
stake-reward querying is still tracked in
[#58](https://github.com/lambdasistemi/amaru-treasury-tx/issues/58).
Until that lands, real invocations abort with a typed trace line before
writing an intent. The pure translation and resolver tests cover the
positive-rewards path through a stubbed provider.

Positive rewards:

- stdout contains exactly one JSON document unless `--out` is supplied;
- `--out PATH` writes the JSON document to `PATH`;
- trace lines go to stderr unless `--log PATH` is supplied;
- exit code is 0.

Zero rewards:

- no JSON is written to stdout or `--out`;
- trace contains a typed "nothing to withdraw" event;
- exit code is 0.

Failure:

- no partial JSON is written;
- one human-readable error line is emitted;
- exit code is non-zero.

## Trace events

Required trace surface:

- network selected
- metadata loaded
- registry verified
- scope selected
- treasury reward account resolved
- reward balance queried
- zero-rewards no-op
- wallet UTxO selected
- validity upper bound computed
- intent written
- abort
