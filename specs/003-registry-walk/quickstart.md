# Quickstart: registry walk with on-chain anchor verification

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

## 1. Library usage (post-merge)

```haskell
import Amaru.Treasury.Registry.Verify
    ( verifyRegistry
    , VerifiedRegistry
    , RegistryWalkError
    )
import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Scope (ScopeId (..))
import qualified Data.Set as Set

example :: Provider IO -> IO (Either RegistryWalkError VerifiedRegistry)
example backend =
    verifyRegistry
        backend
        "metadata.json"
        (Set.singleton CoreDevelopment)
```

Returns `Right VerifiedRegistry` only if every metadata claim
checked against an on-chain anchor or matched a build-time
recomputation.

## 2. CLI usage (lands on PR #28's rebase)

```bash
amaru-treasury-tx \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network mainnet \
    swap-wizard \
    --metadata /path/to/metadata.json \
    --wallet-addr addr1q... \
    --scope core_development \
    --usdm 100000 --chunk-usdm 3062.5 --min-rate 0.245 \
    --validity-hours 6 \
    ...
    --out intent.json --verbose --yes
```

No `--registry PATH`. Metadata is a required local file for
this PR; URL/default fetching is deferred.

## 3. What "verified" actually checks

For the requested scope:

| Field | Verification |
|---|---|
| `owner` | matches the entry in the on-chain Scopes NFT datum |
| `treasury_script.hash` | matches the on-chain per-scope `ScriptHashRegistry` datum's `treasury` AND matches `derivedTreasuryScriptHash(scope)` |
| `registry_script.hash` | matches `policyId(treasury_registry(registry_seed, scope))` |
| `permissions_script.hash` | matches `scriptHash(permissions(scopes_nft_policy, scope))` |
| `address` | matches bech32 of verified `treasury_script.hash` for the network (payment=stake=treasury hash) |
| `treasury_script.deployed_at` | UTxO unspent AND carries verified treasury script as reference script |
| `permissions_script.deployed_at` | UTxO unspent AND carries verified permissions script as reference script |
| `registry_script.deployed_at` | UTxO unspent AND carries the per-scope registry NFT (this UTxO IS the registry NFT location, with inline `ScriptHashRegistry` datum — there is no reference script here) |
| `scope_owners` | UTxO unspent AND holds the derived Scopes NFT, with parseable owners datum |

Plus: each NFT-bearing UTxO must be the unique one matching its
TxIn (the trap validators forbid more than one NFT in circulation
in normal operation; ambiguity = abort).

The chain side is one acquired LSQ session, one
`queryUTxOByTxInH` query over `scope_owners` ∪ each requested
scope's three `*.deployed_at` TxIns. No script-address derivation
is involved in the query — that removes a class of bug where a
wrong stake-reference convention silently returns empty UTxOs.

## 4. When things go wrong

| Exit | Wizard says | Action |
|------|-------------|--------|
| 3 | `metadata: read error: <msg>` | check `--metadata` points to a readable file |
| 3 | `metadata: parse error: <msg>` | upstream schema may have shifted; update parser |
| 3 | `chain: AnchorMismatch <field> <scope>: expected <X>, got <Y>` | metadata's claim disagrees with chain or build-time derivation; investigate before trusting either |
| 3 | `chain: AnchorSpent <field> <scope>: <txin>` | the named reference UTxO has been consumed — likely a re-deployment; bump metadata source to a post-redeploy version |
| 3 | `chain: AnchorAmbiguous <field> <scope>: [<txin>...]` | more than one NFT-bearing UTxO at a script address — should never happen in normal operation |
| 3 | `chain: provider error: <msg>` | check `--node-socket` |

The wizard never writes a partial JSON. Either everything
verified or nothing was written.
