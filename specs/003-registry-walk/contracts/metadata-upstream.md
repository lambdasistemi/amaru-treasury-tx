# Contract: metadata source + chain anchors + Provider extension

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file pins the contracts the verifier relies on. Anything
outside this is a breaking change.

## 1. Metadata source

The verifier reads `metadata.json` from one of three
interchangeable sources, picked by CLI flag:

- **Default**:
  `https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json`.
  Used when no flag is given.
- **`--metadata-url <url>`**: an arbitrary URL. No restriction.
- **`--metadata-file <path>`**: a local filesystem path.

`--metadata-url` and `--metadata-file` are mutually exclusive.
Passing both produces `MetadataSourceConflict` at parse time.

The metadata's *content* is treated as untrusted regardless of
source.

## 2. JSON schema

```json
{
  "scope_owners": "<txid hex>#<ix>",
  "treasuries": {
    "<scope-name>": {
      "owner": "<28-byte hex>" | null,
      "address": "<bech32>",
      "treasury_script": { "hash": "<28-byte hex>", "deployed_at": "<txid hex>#<ix>" },
      "permissions_script": { "hash": "<28-byte hex>", "deployed_at": "<txid hex>#<ix>" },
      "registry_script": { "hash": "<28-byte hex>", "deployed_at": "<txid hex>#<ix>" }
    }
  }
}
```

Scope keys: `core_development`, `ops_and_use_cases`,
`network_compliance`, `middleware`, `contingency`. Extra fields
(e.g. `budget`) are ignored. `owner` is `null` only for
`contingency`.

## 3. On-chain anchors

| Anchor | Where | What it commits to |
|---|---|---|
| Scopes NFT inline datum | UTxO at script address `scopes(scopes_seed)` carrying token `(policy = scopesNftPolicy, name = "amaru 2026 scopes")` | Four scope-owner key hashes (`MultisigScript.Signature` constructors) |
| Per-scope registry NFT inline datum | UTxO at script address `treasury_registry(registry_seed, scope)` carrying token `(policy = perScopeRegistryPolicy, name = "REGISTRY")` | `ScriptHashRegistry { treasury, vendor }` — `treasury` is the per-scope treasury validator hash |

`scopesNftPolicy = scriptHash(applyParams(scopesValidatorBlob,
[scopes_seed]))`.

`perScopeRegistryPolicy[scope] =
scriptHash(applyParams(treasuryRegistryValidatorBlob,
[registry_seed, scope]))`.

`permissionsScriptHash[scope] =
scriptHash(applyParams(permissionsValidatorBlob,
[scopesNftPolicy, scope]))`.

The per-scope treasury validator hash is recoverable in
principle by parameter-applying the SundaeSwap
treasury-contracts validator with a `TreasuryConfiguration`,
but the cleaner path is to read it from the per-scope registry
NFT's inline datum (anchored).

## 4. Provider IO requirement

`Provider IO` must expose:

```haskell
queryUTxOsAt
    :: Provider IO
    -> Set Addr
    -> IO (Map Addr [(TxIn, TxOut ConwayEra)])
```

Each `Addr` in the set produces one entry in the result map
(empty list if no UTxOs at that address). Backed by LSQ
`GetUTxOByAddress` accepting a `Set Addr` natively.

The verifier consumes this twice in total per run alongside
the existing `queryUTxOByTxIn`:

- Round-trip 1: `queryUTxOsAt` over the scopes-validator
  address + each requested scope's registry-validator address.
- Round-trip 2: `queryUTxOByTxIn` over `scope_owners` +
  every requested-scope's `*.deployed_at` TxIn.

Cross-call atomicity (single Acquired session for both) is
tracked at
[lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126).

## 5. Build-time pin

Constants and Plutus blobs in
`Amaru.Treasury.Registry.Constants` are pinned to a specific
upstream commit of `pragma-org/amaru-treasury`. The pin lives
in `flake.nix` (Nix builds) and a comment block above the
constants (non-Nix). Advancing the pin is one PR.

## 6. Out of scope

- Discovering `*_deployed_at` from chain alone (would require
  an indexer or whole-UTxO-set walk).
- Air-gapped operation. `--metadata-file` accommodates pre-
  fetched files but the chain check still runs against
  `Provider IO`.
- Cross-call LSQ atomicity (see §4).
