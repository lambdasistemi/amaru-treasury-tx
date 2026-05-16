# Contract: DevNet Registry Initiator

## CLI Command

Command shape:

```bash
amaru-treasury-tx --network devnet --node-socket <socket> \
  devnet registry-init \
  --funding-address <addr_test...> \
  --signing-key-file <payment.skey> \
  --run-dir <run-dir>
```

The command MUST reject non-DevNet networks before signing or
submitting. It MUST call `Amaru.Treasury.Devnet.RegistryInit`; it MUST
NOT reconstruct registry publication transactions in CLI glue.

Expected success stdout lines:

```text
registry-init: run-dir <run-dir>
registry-init: network devnet magic 42
registry-init: phase registry-init passed
registry-init: seed-split-tx-id <tx-id>
registry-init: registry-mint-tx-id <tx-id>
registry-init: reference-scripts-tx-id <tx-id>
registry-init: summary <run-dir>/registry-init/summary.json
registry-init: registry <run-dir>/registry-init/registry.json
```

## Smoke Phase

Command:

```bash
just devnet-smoke registry-init
```

Equivalent script invocation:

```bash
scripts/smoke/devnet-local --phase registry-init --run-dir <run-dir>
```

Expected success stdout lines:

```text
devnet-smoke: run-dir <run-dir>
devnet-smoke: network devnet magic 42
devnet-smoke: phase registry-init passed
devnet-smoke: registry-init-seed-split-tx-id <tx-id>
devnet-smoke: registry-init-registry-mint-tx-id <tx-id>
devnet-smoke: registry-init-reference-scripts-tx-id <tx-id>
devnet-smoke: registry-init-summary <run-dir>/registry-init/summary.json
devnet-smoke: registry-init-registry <run-dir>/registry-init/registry.json
```

## Success Artifacts

`registry-init/summary.json`:

```json
{
  "phase": "registry-init",
  "network": "devnet",
  "networkMagic": 42,
  "seedSplitTxId": "<hex tx id>",
  "registryMintTxId": "<hex tx id>",
  "referenceScriptsTxId": "<hex tx id>",
  "registryPath": "<run-dir>/registry-init/registry.json",
  "provenancePath": "<run-dir>/registry-init/provenance.json"
}
```

`registry-init/registry.json`:

```json
{
  "phase": "registry-init",
  "network": "devnet",
  "anchors": {
    "scopesDeployedAt": "<tx-id>#<ix>",
    "registryDeployedAt": "<tx-id>#<ix>",
    "permissionsDeployedAt": "<tx-id>#<ix>",
    "treasuryDeployedAt": "<tx-id>#<ix>"
  },
  "policies": {
    "scopesPolicyId": "<policy id>",
    "registryPolicyId": "<policy id>"
  },
  "scripts": {
    "permissionsScriptHash": "<script hash>",
    "treasuryScriptHash": "<script hash>"
  },
  "addresses": {
    "treasuryAddress": "<addr_test...>"
  },
  "owners": {
    "scopeOwnerKeyHash": "<key hash>"
  },
  "submittedTxIds": {
    "seedSplit": "<tx id>",
    "registryMint": "<tx id>",
    "referenceScripts": "<tx id>"
  }
}
```

`registry-init/provenance.json`:

```json
{
  "phase": "registry-init",
  "source": "amaru-treasury-tx",
  "issue": 147,
  "parentIssue": 151
}
```

## Failure Artifact

`registry-init/failure.json`:

```json
{
  "phase": "registry-init",
  "code": "<stable-code>",
  "message": "<human-readable failure>",
  "failedStep": "seed-split | registry-mint | reference-scripts | verify-anchors",
  "observedTxIds": {
    "seedSplit": "<optional tx id>",
    "registryMint": "<optional tx id>",
    "referenceScripts": "<optional tx id>"
  },
  "missingAnchors": ["<anchor name>"],
  "summaryPath": "<run-dir>/registry-init/failure.json"
}
```

## Review Contract

- The production module owns registry publication transaction
  construction.
- `SmokeSpec.hs` owns phase selection, calling the production module,
  and asserting observed chain effects.
- Later phases consume the artifact or production projection; they do
  not duplicate registry transaction construction.
