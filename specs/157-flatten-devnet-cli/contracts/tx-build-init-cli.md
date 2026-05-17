# Contract: `tx-build --intent <bootstrap-intent.json>` (init sub-actions)

After #157 the operator path for any of the seven init sub-actions
is the existing unified `tx-build` command:

```bash
amaru-treasury-tx tx-build \
  --intent <bootstrap-intent.json> \
  [--out <unsigned-tx.cbor.hex>] \
  [--log <log-path>] \
  [--report <report.json>]
```

No `tx-build` flags change. The `--intent` flag accepts the same
JSON envelope as for `swap` / `disburse` / `withdraw`; the
discriminator is the flat `action` tag.

## Inputs

- `<bootstrap-intent.json>` — produced manually for the golden
  goldens (test-support helper), or by the wizards in #158–#160
  for operator use.
- `--out` (optional) — write unsigned tx CBOR hex here; default
  stdout.
- `--log` (optional) — write step-by-step trace lines here;
  default stderr.
- `--report` (optional) — write a deterministic JSON
  transaction report.

## Outputs

- One unsigned tx CBOR hex per invocation.
- Optional JSON report describing the build.

## Failure modes

- `network ≠ devnet` → decoder error before any N2C connection.
- Unknown `action` tag → decoder error.
- Mismatched `action` / `payload` → typed decoder error.
- Build failure (e.g., missing required UTxO) → typed build error;
  stderr + optional failure report; non-zero exit.

## Removed CLI surface

- `amaru-treasury-tx devnet …` (the entire nested supercommand).
- `amaru-treasury-tx devnet registry-init …`.
- `amaru-treasury-tx devnet stake-reward-init …`.
- `amaru-treasury-tx devnet governance-withdrawal-init …`.
- `amaru-treasury-tx devnet disburse-submit …`.

After #157 these are unrecognized subcommands.

## Operator chain per init action (illustrative)

For `registry-init`, three iterations:

```bash
# 1. Seed split
registry-init-wizard seed-split > intent.json   # ships in #158
amaru-treasury-tx tx-build --intent intent.json --out tx.cbor.hex
amaru-treasury-tx witness --tx tx.cbor.hex --signer …
amaru-treasury-tx submit  --tx tx.cbor.hex --witnesses …

# 2. Mint registry/scopes NFTs (consumes seed-split outputs)
registry-init-wizard mint --seed-txs … > intent.json
... tx-build / witness / submit

# 3. Reference scripts (consumes mint output)
registry-init-wizard reference-scripts --registry-deployed-at … > intent.json
... tx-build / witness / submit
```

Wizards arrive in #158–#160; for #157 the producer side is the
golden test-support helper.
