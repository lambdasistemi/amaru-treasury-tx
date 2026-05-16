# Contract: DevNet Disburse Submit

## CLI Command

```bash
amaru-treasury-tx --network devnet --node-socket <socket> \
  devnet disburse-submit \
  --registry-file <run-dir>/registry-init/registry.json \
  --materialized-file <run-dir>/governance-withdrawal-init/materialized.json \
  --funding-address <addr_test...> \
  --signing-key-file <payment.skey> \
  --beneficiary-address <addr_test...> \
  --run-dir <run-dir> \
  [--amount-lovelace 1000000]
```

The command MUST reject non-DevNet networks before reading key material,
opening the node socket, submitting transactions, or writing success
artifacts.

## Success Stdout

```text
disburse-submit: run-dir <run-dir>
disburse-submit: network devnet magic 42
disburse-submit: phase disburse-submit passed
disburse-submit: submitted-tx-id <tx-id>
disburse-submit: beneficiary-address <addr_test...>
disburse-submit: beneficiary-tx-in <tx-id>#<ix>
disburse-submit: beneficiary-lovelace <integer>
disburse-submit: treasury-input <tx-id>#<ix>
disburse-submit: treasury-lovelace-before <integer>
disburse-submit: treasury-lovelace-after <integer>
disburse-submit: signed-tx <run-dir>/disburse-submit/signed-tx.cbor.hex
disburse-submit: submit-log <run-dir>/disburse-submit/submit.log
disburse-submit: summary <run-dir>/disburse-submit/summary.json
```

## Smoke Phase

```bash
just devnet-smoke disburse-submit
```

The smoke may start a fresh DevNet and run `registry-init`,
`stake-reward-init`, and `governance-withdrawal-init` first. #150
behavior MUST go through the same command runner used by the shipped
CLI command.

## Success Artifacts

All command-owned success artifacts live under:

```text
<run-dir>/disburse-submit/
```

Required artifacts:

- `summary.json`
- `disburse.json`
- `beneficiary.json`
- `treasury.json`
- `provenance.json`
- `intent.json`
- `tx-body.cbor.hex`
- `report.json`
- `report.md`
- `signed-tx.cbor.hex`
- `submit.log`

## Review Contract

- Production code owns disburse intent construction, tx-build,
  signing/submission, and treasury/beneficiary verification.
- CLI glue owns parsing, DevNet-only validation, input decoding, and
  runner invocation.
- `SmokeSpec.hs` owns DevNet process setup, prerequisite command
  orchestration, runner invocation, and artifact/effect assertions.
- #150 consumes #149 `materialized.json`; it does not re-run #149
  behavior inside its production command.
