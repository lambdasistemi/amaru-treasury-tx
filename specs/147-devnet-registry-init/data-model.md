# Data Model: DevNet Registry Initiator

## RegistryInitRun

One opt-in local DevNet execution.

- `runDir`: root run directory.
- `socket`: local node socket used by the proof.
- `networkMagic`: expected DevNet magic, currently `42`.
- `timing`: observed DevNet timing summary.
- `registryPublication`: successful publication record, when present.
- `diagnostic`: typed failure record, when present.

Validation rules:

- A run has either `registryPublication` or `diagnostic`, not both.
- Success artifacts must be written under `registry-init/`.
- Stale success artifacts from prior runs must not survive a failed run.

## RegistryPublication

Submitted chain effects for the registry bootstrap.

- `seedSplitTxId`: transaction id that splits bootstrap ADA into seed
  UTxOs.
- `registryMintTxId`: transaction id that mints scopes and registry
  NFTs.
- `referenceScriptsTxId`: transaction id that publishes permissions and
  treasury reference scripts.
- `scopesDeployedAt`: TxIn for the scopes NFT UTxO.
- `registryDeployedAt`: TxIn for the registry NFT UTxO.
- `permissionsDeployedAt`: TxIn for the permissions reference script.
- `treasuryDeployedAt`: TxIn for the treasury reference script.

Validation rules:

- Each TxIn must be observed through a local node query before success.
- The registry NFT UTxO must carry the expected registry datum.
- Reference-script UTxOs must carry a reference script whose hash
  matches the artifact hash.

## RegistryArtifact

Durable handoff JSON for later DevNet slices.

- `phase`: `registry-init`.
- `network`: `devnet`.
- `registryPolicyId`: policy id for the registry NFT.
- `scopesPolicyId`: policy id for the scopes NFT.
- `permissionsScriptHash`: permissions validator hash.
- `treasuryScriptHash`: treasury validator hash.
- `treasuryAddress`: testnet Bech32 treasury script address.
- `ownerKeyHash`: owner key hash used in local scope-owner datum.
- `submittedTxIds`: seed split, registry mint, and reference-script tx
  ids.
- `anchors`: scopes, registry, permissions, and treasury TxIns.

Validation rules:

- The artifact must contain every field needed to construct the
  withdraw/disburse registry view.
- Hash and TxIn values must be rendered as stable text, not Haskell
  `Show` output that changes shape.

## RegistryInitDiagnostic

Typed failure information for unsuccessful runs.

- `phase`: failed subphase such as `seed-split`, `registry-mint`,
  `reference-scripts`, or `verify-anchors`.
- `code`: stable diagnostic code.
- `message`: human-readable explanation.
- `observedTxIds`: tx ids submitted before failure.
- `missingAnchors`: expected anchors not observed before timeout.
- `artifactPath`: path to the diagnostic JSON.

Validation rules:

- Diagnostics must be machine-readable and must not masquerade as a
  success summary.
- A diagnostic may preserve partial tx ids for reproduction, but must
  not claim the registry handoff is usable.
