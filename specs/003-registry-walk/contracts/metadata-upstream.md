# Contract: `metadata.json` schema mirror + URL

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file pins the JSON schema the wizard's parser accepts and
the URL it fetches from. Anything outside this contract is a
breaking change.

## 1. URL

```
https://raw.githubusercontent.com/pragma-org/amaru-treasury/<sha>/journal/2026/metadata.json
```

- `<sha>` is a 40-char hex SHA-1 commit hash. No branches, no
  tags.
- Default `<sha>` is the `defaultUpstreamCommit` constant in
  `Amaru.Treasury.Metadata.Upstream`. Override via
  `--metadata-commit`.
- The wizard does NOT follow redirects beyond GitHub's standard
  raw-blob redirect.
- Required: HTTPS, no auth.

## 2. JSON schema

```json
{
  "scope_owners": "<txid hex>#<ix>",
  "treasuries": {
    "<scope-name>": {
      "owner": "<28-byte hex>" | null,
      "address": "<bech32>",
      "treasury_script": {
        "hash": "<28-byte hex>",
        "deployed_at": "<txid hex>#<ix>"
      },
      "permissions_script": {
        "hash": "<28-byte hex>",
        "deployed_at": "<txid hex>#<ix>"
      },
      "registry_script": {
        "hash": "<28-byte hex>",
        "deployed_at": "<txid hex>#<ix>"
      }
    }
  }
}
```

Required scope keys: `core_development`, `ops_and_use_cases`,
`network_compliance`, `middleware`, `contingency`.

Notes:
- `owner` is `null` only for `contingency`; the parser accepts
  this and projects to `Nothing`.
- Extra unknown fields (e.g. `budget`) are ignored.

## 3. Fetcher contract

```haskell
runFetcher :: Text -> m (Either MetadataError ByteString)
```

- Input: full URL.
- Output:
  - `Right body` for HTTP 200 with a non-empty body.
  - `Left (MetadataFetchHttp status url)` for non-200.
  - `Left (MetadataFetchTimeout url)` if the request timed out
    at the configured limit (10 s default).
  - `Left (MetadataFetchTransport msg)` for DNS/TLS/socket
    failures.

## 4. Verifier contract

For each TxIn in the verify-set
([data-model.md §4](../data-model.md)):

```haskell
queryUTxOByTxIn (Set.singleton ref) :: IO (Map TxIn (TxOut ConwayEra))
```

If the returned map is empty, the ref is consumed: emit
`ChainVerificationSpent ref label`.

Errors from the Provider itself (network drop, exception) bubble
as `ChainVerificationProviderError`.

## 5. Pin update procedure

To advance `defaultUpstreamCommit`:

1. Open a PR that updates ONLY the constant and (optionally) the
   checked-in fixture.
2. Reviewer cross-checks the new SHA against
   `pragma-org/amaru-treasury/journal/2026/metadata.json` at
   that commit.
3. Confirm `just ci` is green with the new fixture.
4. Merge.

## 6. Out of scope

- Schema migration (e.g. upstream renames a field). When that
  happens we reject parsing and require a code change.
- Local-file metadata input. There is no
  `--metadata-path` flag.
- Air-gapped operation. Out of scope for v1.
