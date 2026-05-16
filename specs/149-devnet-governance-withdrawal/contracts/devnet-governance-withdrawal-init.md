# Contract: DevNet Governance And Withdrawal Init

## CLI Command

Command shape:

```bash
amaru-treasury-tx --network devnet --node-socket <socket> \
  devnet governance-withdrawal-init \
  --registry-file <run-dir>/registry-init/registry.json \
  --stake-reward-file <run-dir>/stake-reward-init/accounts.json \
  --funding-address <addr_test...> \
  --signing-key-file <payment.skey> \
  --run-dir <run-dir> \
  [--amount-lovelace 2000000] \
  [--reward-timeout-seconds 180]
```

The command MUST reject non-DevNet networks before reading the signing
key, opening the node socket, submitting transactions, or writing
success artifacts. It MUST call a production-backed DevNet
governance/withdrawal setup module; it MUST NOT reconstruct #149
transactions in CLI glue or in the smoke layer.

## Success Stdout

Expected success stdout lines:

```text
governance-withdrawal-init: run-dir <run-dir>
governance-withdrawal-init: network devnet magic 42
governance-withdrawal-init: phase governance-withdrawal-init passed
governance-withdrawal-init: governance-proposal-tx-id <tx-id>
governance-withdrawal-init: governance-action-id <tx-id>#<ix>
governance-withdrawal-init: vote-tx-id <tx-id>
governance-withdrawal-init: treasury-reward-account <28-byte-hex>
governance-withdrawal-init: reward-before-lovelace <integer>
governance-withdrawal-init: reward-after-governance-lovelace <integer>
governance-withdrawal-init: withdraw-tx-id <tx-id>
governance-withdrawal-init: withdraw-submitted-tx-id <tx-id>
governance-withdrawal-init: treasury-materialized-tx-in <tx-id>#<ix>
governance-withdrawal-init: treasury-materialized-ada <integer>
governance-withdrawal-init: summary <run-dir>/governance-withdrawal-init/summary.json
governance-withdrawal-init: materialization <run-dir>/governance-withdrawal-init/materialized.json
```

The prefix is command-specific, not `devnet-smoke`. Smoke may echo
additional proof lines, but the command output contract remains the
primary operator contract.

## Smoke Phase

Primary proof command:

```bash
just devnet-smoke governance-withdrawal-init
```

Equivalent script invocation:

```bash
scripts/smoke/devnet-local --phase governance-withdrawal-init --run-dir <run-dir>
```

The smoke may start a governance-enabled local DevNet by copying and
patching genesis files. It may run `registry-init` and
`stake-reward-init` first in the same fresh run. #149 behavior MUST go
through the same command runner used by the shipped CLI command.

If `withdraw` remains accepted by `scripts/smoke/devnet-local`, it MUST
be an alias for the same production command proof or be removed from the
documented passing phase list.

Accepted PR #154 proof:

```text
run-dir: runs/devnet/20260516T231003Z
proposal-tx-id: baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23
governance-action-id: baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0
vote-tx-id: 009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45
treasury-reward-account: b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4
withdrawal-tx-id: 4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd
materialized-tx-in: 4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0
materialized-ada: 2000000
reward-movement: 0 -> 2000000 -> 0
treasury-ada-movement: 200000000 -> 202000000
```

## Success Artifacts

All command-owned success artifacts live under:

```text
<run-dir>/governance-withdrawal-init/
```

`summary.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "status": "passed",
  "network": "devnet",
  "networkMagic": 42,
  "runDirectory": "<run-dir>",
  "registryPath": "<run-dir>/registry-init/registry.json",
  "stakeRewardPath": "<run-dir>/stake-reward-init/accounts.json",
  "amountLovelace": 2000000,
  "governancePath": "<run-dir>/governance-withdrawal-init/governance.json",
  "withdrawalPath": "<run-dir>/governance-withdrawal-init/withdrawal.json",
  "materializationPath": "<run-dir>/governance-withdrawal-init/materialized.json",
  "provenancePath": "<run-dir>/governance-withdrawal-init/provenance.json"
}
```

`governance.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "network": "devnet",
  "proposalTxId": "<hex tx id>",
  "governanceActionId": "<tx-id>#<ix>",
  "voteTxId": "<hex tx id>",
  "treasuryRewardAccount": "<28-byte-hex>",
  "treasuryScriptHash": "<28-byte-hex>",
  "amountLovelace": 2000000,
  "rewardBeforeLovelace": 0,
  "rewardAfterGovernanceLovelace": 2000000,
  "setupEpoch": 2,
  "voteEpoch": 3,
  "finalEpoch": 4
}
```

`withdrawal.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "network": "devnet",
  "intentPath": "<run-dir>/governance-withdrawal-init/intent.json",
  "txBodyPath": "<run-dir>/governance-withdrawal-init/tx-body.cbor.hex",
  "reportJsonPath": "<run-dir>/governance-withdrawal-init/report.json",
  "reportMarkdownPath": "<run-dir>/governance-withdrawal-init/report.md",
  "txBuildLogPath": "<run-dir>/governance-withdrawal-init/tx-build.log",
  "signedTxPath": "<run-dir>/governance-withdrawal-init/signed-tx.cbor.hex",
  "submitLogPath": "<run-dir>/governance-withdrawal-init/submit.log",
  "txId": "<hex tx id>",
  "submittedTxId": "<hex tx id>",
  "feeLovelace": 0,
  "rewardBeforeSubmitLovelace": 2000000,
  "rewardAfterSubmitLovelace": 0
}
```

`materialized.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "network": "devnet",
  "governanceActionId": "<tx-id>#<ix>",
  "treasuryRewardAccount": "<28-byte-hex>",
  "submittedTxId": "<hex tx id>",
  "treasuryMaterializedTxIn": "<tx-id>#<ix>",
  "treasuryAddress": "addr_test1...",
  "materializedAdaLovelace": 2000000,
  "rewardBeforeSubmitLovelace": 2000000,
  "rewardAfterSubmitLovelace": 0,
  "treasuryUtxoLovelaceBefore": 0,
  "treasuryUtxoLovelaceAfter": 2000000,
  "registryPath": "<run-dir>/registry-init/registry.json",
  "stakeRewardPath": "<run-dir>/stake-reward-init/accounts.json"
}
```

`provenance.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "source": "amaru-treasury-tx",
  "issue": 149,
  "parentIssue": 151,
  "dependsOnIssues": [147, 148]
}
```

The implementation may include additional fields, but it MUST NOT drop
the fields listed above without updating this contract and the tasks.

## Failure Artifact

`failure.json`:

```json
{
  "phase": "governance-withdrawal-init",
  "status": "failed",
  "code": "<stable-code>",
  "message": "<human-readable failure>",
  "failedStep": "validate-inputs | governance-build | governance-submit | vote-submit | reward-wait | withdraw-intent | withdraw-build | withdraw-submit | materialization-verify",
  "observedTxIds": {
    "proposal": "<optional tx id>",
    "vote": "<optional tx id>",
    "withdrawal": "<optional tx id>"
  },
  "lastObservedRewardLovelace": 0,
  "epoch": 0,
  "tipSlot": 0,
  "summaryPath": "<run-dir>/governance-withdrawal-init/failure.json"
}
```

Failure writes MUST remove stale success summaries and preserve partial
submission evidence when it exists.

## Review Contract

- Production code owns governance proposal, vote, reward wait,
  withdrawal intent, tx-build, signing, submission, materialization
  verification, and artifact projection.
- CLI glue owns parsing, DevNet-only validation, input decoding, and
  calling the production runner.
- `SmokeSpec.hs` owns DevNet process setup, prerequisite command
  orchestration, calling the production command runner, and asserting
  observed chain effects.
- #149 consumes #147 and #148 artifacts. It must not repeat their setup.
- #150 consumes the `materialized.json` treasury UTxO handoff.
