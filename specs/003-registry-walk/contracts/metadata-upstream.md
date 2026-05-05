# Contract: metadata source + chain anchors + Provider extension

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file pins the contracts the verifier relies on. Anything
outside this is a breaking change.

## 1. Metadata source

The verifier reads `metadata.json` from a local filesystem path
supplied by the operator:

- **`--metadata <path>`**: local metadata snapshot.

The metadata's *content* is treated as untrusted. HTTP(S)
fetching, default upstream URLs, and mirror selection are
deferred until there is an explicit request for that
ergonomics.

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

`treasuryScriptHash[scope] =
scriptHash(applyParams(treasuryValidatorBlob,
[TreasuryConfiguration registryToken permissionsScriptHash]))`.

The per-scope registry NFT datum must commit to the same
treasury script hash.

## 4. Provider IO requirement

`Provider IO` must expose:

```haskell
withAcquired
    :: Provider IO
    -> (QueryHandle IO -> IO a)
    -> IO a

queryUTxOsAtH
    :: QueryHandle IO
    -> Set Addr
    -> IO (Map Addr [(TxIn, TxOut ConwayEra)])

queryUTxOByTxInH
    :: QueryHandle IO
    -> Set TxIn
    -> IO (Map TxIn (TxOut ConwayEra))
```

Each `Addr` in the set produces one entry in the result map
(empty list if no UTxOs at that address). Backed by LSQ
`GetUTxOByAddress` accepting a `Set Addr` natively. The
verifier does not use this entry point — see below.

The verifier consumes one acquired session per run, with
**exactly one query**:

- `queryUTxOByTxInH` over `scope_owners` ∪ each requested
  scope's three `*.deployed_at` TxIns (treasury, permissions,
  registry).

`queryUTxOsAtH` was used in an earlier draft of the verifier to
discover NFT-bearing UTxOs at a derived script address. Mainnet
smoke testing surfaced two reasons that approach was unsafe:

1. The derived script address depends on a stake-reference
   convention (e.g. `StakeRefBase ScriptHashObj` vs
   `StakeRefNull`) that we cannot infer from the policy alone.
   A wrong convention makes `queryUTxOsAtH` silently return
   `[]`, which in turn produces a misleading
   `AnchorSpent`.
2. The metadata already names every UTxO we need:
   `scope_owners` is the Scopes NFT TxIn; each scope's
   `registry_script.deployed_at` is the per-scope registry NFT
   TxIn (not a reference-script UTxO — the on-chain UTxO has
   an inline `ScriptHashRegistry` datum and no reference
   script).

Querying by TxIn removes the stake-reference dependency, halves
the number of LSQ round-trips, and matches the upstream bash
recipes (`swap.sh` etc.) which `jq` the same TxIns directly.

Implemented upstream by
[lambdasistemi/cardano-node-clients#128](https://github.com/lambdasistemi/cardano-node-clients/pull/128),
closing
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
- HTTP(S) metadata fetching and default upstream URLs.
- Fully air-gapped operation. A local file can be pre-fetched,
  but the chain check still runs against `Provider IO`.
