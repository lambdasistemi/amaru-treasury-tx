# Contract: DevNet Stake And Reward Setup

## CLI Command

Command shape:

```bash
amaru-treasury-tx --network devnet --node-socket <socket> \
  devnet stake-reward-init \
  --registry-file <run-dir>/registry-init/registry.json \
  --funding-address <addr_test...> \
  --signing-key-file <payment.skey> \
  --run-dir <run-dir>
```

The command MUST reject non-DevNet networks before signing or
submitting. It MUST call a production-backed DevNet stake/reward setup
module; it MUST NOT reconstruct setup transactions in CLI glue.

Expected success stdout lines:

```text
stake-reward-init: run-dir <run-dir>
stake-reward-init: network devnet magic 42
stake-reward-init: phase stake-reward-init passed
stake-reward-init: setup-tx-id <tx-id>
stake-reward-init: treasury-reward-account <28-byte-hex>
stake-reward-init: permissions-reward-account <28-byte-hex>
stake-reward-init: summary <run-dir>/stake-reward-init/summary.json
stake-reward-init: accounts <run-dir>/stake-reward-init/accounts.json
```

## Smoke Phase

Command:

```bash
just devnet-smoke stake-reward-init
```

Equivalent script invocation:

```bash
scripts/smoke/devnet-local --phase stake-reward-init --run-dir <run-dir>
```

The smoke may run registry-init first in the same fresh DevNet run. The
stake/reward setup proof MUST go through the same command runner used by
the shipped CLI command.

Expected success stdout lines:

```text
stake-reward-init: run-dir <run-dir>
stake-reward-init: network devnet magic 42
stake-reward-init: phase stake-reward-init passed
stake-reward-init: setup-tx-id <tx-id>
stake-reward-init: treasury-reward-account <28-byte-hex>
stake-reward-init: permissions-reward-account <28-byte-hex>
stake-reward-init: summary <run-dir>/stake-reward-init/summary.json
stake-reward-init: accounts <run-dir>/stake-reward-init/accounts.json
```

## Success Artifacts

`stake-reward-init/summary.json`:

```json
{
  "phase": "stake-reward-init",
  "network": "devnet",
  "networkMagic": 42,
  "registryPath": "<run-dir>/registry-init/registry.json",
  "setupTxId": "<hex tx id>",
  "accountsPath": "<run-dir>/stake-reward-init/accounts.json",
  "provenancePath": "<run-dir>/stake-reward-init/provenance.json"
}
```

`stake-reward-init/accounts.json`:

```json
{
  "phase": "stake-reward-init",
  "network": "devnet",
  "accounts": {
    "treasury": {
      "scriptHash": "<28-byte-hex>",
      "rewardAccount": "<28-byte-hex>",
      "ledgerNetwork": "Testnet",
      "registered": true,
      "rewardsLovelace": 0
    },
    "permissions": {
      "scriptHash": "<28-byte-hex>",
      "rewardAccount": "<28-byte-hex>",
      "ledgerNetwork": "Testnet",
      "registered": true,
      "rewardsLovelace": 0
    }
  }
}
```

`stake-reward-init/provenance.json`:

```json
{
  "phase": "stake-reward-init",
  "source": "amaru-treasury-tx",
  "issue": 148,
  "parentIssue": 151,
  "dependsOnIssue": 147
}
```

## Failure Artifact

`stake-reward-init/failure.json`:

```json
{
  "phase": "stake-reward-init",
  "code": "<stable-code>",
  "message": "<human-readable failure>",
  "failedStep": "validate-inputs | build | submit | verify",
  "observedTxIds": {
    "setup": "<optional tx id>"
  },
  "summaryPath": "<run-dir>/stake-reward-init/failure.json"
}
```

## Review Contract

- Production code owns setup transaction construction.
- CLI glue owns parsing, validation, and calling the production runner.
- `SmokeSpec.hs` owns DevNet process setup, calling the production
  runner, and asserting observed chain effects.
- #149 consumes the treasury reward-account setup; #150 consumes the
  permissions reward-account setup.
