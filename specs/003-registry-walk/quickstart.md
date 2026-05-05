# Quickstart: Upstream metadata fetch

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file documents how the new module is consumed once it
lands on `main`. The wizard rebase (PR #28 on top of
this branch) is what actually exercises it end-to-end.

## 1. Library usage (post-merge)

```haskell
import Amaru.Treasury.Metadata.Upstream
    ( defaultUpstreamCommit
    , fetchAndVerifyMetadata
    , httpFetcher
    , MetadataError
    , UpstreamMetadata
    )
import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Scope (ScopeId (..))
import Network.HTTP.Client.TLS (newTlsManager)

example :: Provider IO -> IO (Either MetadataError UpstreamMetadata)
example backend = do
    mgr <- newTlsManager
    let fetcher = httpFetcher mgr
    fetchAndVerifyMetadata
        fetcher
        backend
        defaultUpstreamCommit
        CoreDevelopment
```

The returned `UpstreamMetadata` is verified against the chain at
the moment of the call.

## 2. CLI usage (lands on PR #28's rebase)

```bash
amaru-treasury-tx \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network mainnet \
    swap-wizard \
    [--metadata-commit <40-hex-sha>] \   # optional; defaults
    --wallet-addr addr1q... \
    --scope core_development \
    --usdm 100000 --chunk-usdm 3062.5 --min-rate 0.245 \
    --validity-hours 6 \
    ...
    --out intent.json --verbose --yes
```

Notes:
- There is no `--registry PATH` flag. The wizard fetches
  `metadata.json` itself.
- Without `--metadata-commit`, the binary uses its baked-in
  default. Updating the default is a separate PR (see
  [contracts/metadata-upstream.md §5](./contracts/metadata-upstream.md)).

## 3. Verifying the safety check

To exercise the spent-UTxO path locally:

```bash
# pick a deployed_at that's still unspent on mainnet
DEPLOYED_AT=87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#0
# confirm it's unspent (sanity)
cardano-cli query utxo --tx-in $DEPLOYED_AT --mainnet
# … run the wizard against a stub Provider that masks it as spent
# (covered by test/unit/Amaru/Treasury/Metadata/UpstreamSpec.hs)
```

The unit tests are the canonical way to drive the
`ChainVerificationSpent` path; production runs should never see
that branch unless upstream has actually moved a deployed-at
UTxO.

## 4. When things go wrong

| Exit | Wizard says | Action |
|------|-------------|--------|
| 3 | `metadata: <url>: HTTP 404` | check `--metadata-commit` is reachable |
| 3 | `metadata: parse error: <msg>` | upstream schema may have shifted; bump pin or update parser |
| 3 | `chain: <ref> for <label> is no longer unspent` | upstream has redeployed; bump `--metadata-commit` to the post-redeploy commit |
| 3 | `chain: provider error: <msg>` | check `--node-socket` |

The wizard never writes a partial JSON. Either the file is
correct or it does not exist.
