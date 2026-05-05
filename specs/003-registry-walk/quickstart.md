# Quickstart: registry walk with on-chain anchor verification

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

## 1. Library usage (post-merge)

```haskell
import Amaru.Treasury.Registry.Verify
    ( verifyRegistry
    , VerifiedRegistry
    , RegistryWalkError
    , MetadataSource (MetadataSourceDefaultUrl)
    )
import Amaru.Treasury.Registry.Metadata (httpFetcher)
import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Scope (ScopeId (..))
import Network.HTTP.Client.TLS (newTlsManager)
import qualified Data.Set as Set

example :: Provider IO -> IO (Either RegistryWalkError VerifiedRegistry)
example backend = do
    mgr <- newTlsManager
    verifyRegistry
        backend
        (httpFetcher mgr)
        MetadataSourceDefaultUrl
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
    [--metadata-url <url> | --metadata-file <path>] \
    --wallet-addr addr1q... \
    --scope core_development \
    --usdm 100000 --chunk-usdm 3062.5 --min-rate 0.245 \
    --validity-hours 6 \
    ...
    --out intent.json --verbose --yes
```

No `--registry PATH`. Default metadata source is upstream raw
`main`. Both metadata flags are optional and mutually
exclusive.

## 3. What "verified" actually checks

For the requested scope:

| Field | Verification |
|---|---|
| `owner` | matches the entry in the on-chain Scopes NFT datum |
| `treasury_script.hash` | matches the on-chain `ScriptHashRegistry` datum's `treasury` |
| `registry_script.hash` | matches `policyId(treasury_registry(registry_seed, scope))` |
| `permissions_script.hash` | matches `scriptHash(permissions(scopes_nft_policy, scope))` |
| `address` | matches bech32 of verified `treasury_script.hash` for the network |
| `*_deployed_at` | named UTxO is unspent AND carries the verified script hash as reference script |
| `scope_owners` | the UTxO holds the Scopes NFT and is unspent |

Plus: each NFT-bearing UTxO must be the unique one at its script
address (the trap validators forbid more than one in normal
operation; ambiguity = abort).

## 4. When things go wrong

| Exit | Wizard says | Action |
|------|-------------|--------|
| 3 | `metadata: <url>: HTTP 404` | check `--metadata-url` is reachable |
| 3 | `metadata: parse error: <msg>` | upstream schema may have shifted; update parser |
| 3 | `chain: AnchorMismatch <field> <scope>: expected <X>, got <Y>` | metadata's claim disagrees with chain or build-time derivation; investigate before trusting either |
| 3 | `chain: AnchorSpent <field> <scope>: <txin>` | the named reference UTxO has been consumed — likely a re-deployment; bump metadata source to a post-redeploy version |
| 3 | `chain: AnchorAmbiguous <field> <scope>: [<txin>...]` | more than one NFT-bearing UTxO at a script address — should never happen in normal operation |
| 3 | `chain: provider error: <msg>` | check `--node-socket` |

The wizard never writes a partial JSON. Either everything
verified or nothing was written.
