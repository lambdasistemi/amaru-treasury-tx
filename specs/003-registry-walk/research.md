# Phase 0 Research: Upstream metadata fetch + chain sanity-check

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

## R1. What's actually on chain (the source-of-truth audit)

**Decision**: Trust `pragma-org/amaru-treasury/journal/2026/metadata.json`
at a pinned commit, then sanity-check against chain. Do NOT
attempt to derive `*DeployedAt` UTxOs or owner key hashes from
on-chain data.

**Rationale**: Inspection of upstream
[`lib/registry.ak`](https://github.com/pragma-org/amaru-treasury/blob/main/lib/registry.ak)
shows the registry-NFT inline datum is just
`ScriptHashRegistry { treasury, vendor }`. The
`*DeployedAt` UTxOs and the four scope-owner key hashes are
*not* on chain — they live in `journal/2026/metadata.json` in
the same repo. The bash recipes (`swap.sh`, `disburse.sh`)
load that file with `jq`. There is no on-chain link from a
script's hash to the UTxO it's deployed at; that mapping is
upstream's editorial decision recorded in metadata.

**Alternatives considered**:
- Query the chain for UTxOs at the four treasury addresses and
  pick "the one that has the script as a reference script".
  Rejected: ambiguous when more than one such UTxO exists, and
  doesn't recover scope-owner key hashes.
- Walk the registry NFT inline datum to recover all fields.
  Rejected because the datum doesn't carry those fields.

## R2. HTTP source

**Decision**: Pull `metadata.json` from
`https://raw.githubusercontent.com/pragma-org/amaru-treasury/<sha>/journal/2026/metadata.json`.

**Rationale**:
- Stable URL pattern documented by GitHub for raw blob access.
- `<sha>` lets us pin to an exact commit reviewed at release
  time.
- HTTPS only; no auth required for public repos.

**Alternatives considered**:
- The GitHub REST API (`/repos/.../contents/...`). Rejected: API
  rate limits without auth, and the response is base64-wrapped.
- A mirror under `lambdasistemi`. Rejected: an extra surface to
  audit.

## R3. HTTP client

**Decision**: `http-client` + `http-client-tls`.

**Rationale**:
- Already common in the cardano-haskell stack, low-friction.
- Minimal deps; no streaming required (response is small JSON).
- The fetcher sits behind a `MetadataFetcher m` record so the
  unit tests stub it without HTTPS.

**Alternatives considered**:
- `req`. Rejected: one more transitive dep.
- `wreq`. Rejected: too heavy for one GET.

## R4. Pinning mechanism

**Decision**: A `defaultUpstreamCommit :: Text` constant in
`Amaru.Treasury.Metadata.Upstream`, holding a 40-char hex SHA.
Override at runtime via `--metadata-commit <sha>`.

**Rationale**:
- The constant is in source code → updating requires a PR →
  diff-reviewable.
- Override exists for operators who need a newer upstream commit
  before the next release of this binary; they take
  responsibility for that commit's content.

**Alternatives considered**:
- A separate JSON or TOML config file shipped alongside the
  binary. Rejected: same audit-trail problem the original
  `--registry` flag had.
- `flake.lock`-style pinning of the upstream repo as a Nix
  input. Rejected for v1 because the binary needs to be runnable
  outside Nix.

## R5. Sanity-check shape

**Decision**: For every TxIn the metadata names — the top-level
`scope_owners` and each scope's `treasury_script.deployed_at`,
`permissions_script.deployed_at`, `registry_script.deployed_at`
— call `Provider.queryUTxOByTxIn` with the singleton set; if
the returned map is empty, the UTxO is consumed and the wizard
aborts.

**Rationale**:
- Single existing Provider call. No new typeclass methods.
- Catches the most common staleness mode (script re-deploy
  consumes the old reference UTxO).

**Alternatives considered**:
- Also re-query the script address and confirm a UTxO exists
  with the metadata's claimed script hash as its reference
  script. Rejected for v1: more queries, and the spent-UTxO
  check already catches the practical failure.
- Hash-pin the metadata body: compare a SHA-256 of the fetched
  body against a constant in source. Rejected for now: the pin
  is the commit SHA, which is itself a content hash of the
  whole repo at that revision; double-pinning adds churn
  without changing the trust model.

## R6. What about scopes the operator does not request?

**Decision**: Verify only the TxIns referenced by the *requested*
scope plus the global `scope_owners`. Skip the other scopes'
deployed-at refs.

**Rationale**:
- The wizard's output only references those refs.
- Verifying everything makes the wizard refuse to run when an
  unrelated scope's UTxOs have moved, which is noise.

**Alternatives considered**:
- Verify all scopes always. Rejected per above.
- Verify nothing (just project the metadata). Rejected — that's
  the original footgun.

## R7. Fixture-driven testing

**Decision**: Check in `test/fixtures/metadata-upstream/metadata.json`
copied verbatim from a known-good upstream commit. The unit test
stubs the `MetadataFetcher` to return this body and the
`Provider IO` to report all listed TxIns as unspent.

A second `it` block stubs the Provider to report one TxIn as
spent and asserts the typed `ChainVerificationError`.

**Rationale**:
- No HTTPS in tests.
- The fixture's commit SHA is recorded in the README so it's
  auditable.

**Alternatives considered**:
- Hit `raw.githubusercontent.com` from CI. Rejected: external
  dependency in CI tests is a flake source.

## R8. Where the resolver dispatches

**Decision**: `Amaru.Treasury.Metadata.Upstream` exports

```haskell
fetchAndVerifyMetadata
    :: MetadataFetcher IO
    -> Provider IO
    -> Text                  -- commit SHA
    -> ScopeId               -- which scope to verify
    -> IO (Either MetadataError UpstreamMetadata)
```

The wizard rebase (PR #28) replaces its `loadRegistry` call with
this. `MetadataError` is the union of `MetadataFetchError`,
`MetadataParseError`, and `ChainVerificationError`.

**Rationale**: One import for the consumer, all error paths
typed, no IOExceptions leak past this seam.

**Alternatives considered**: Splitting into separate fetch /
verify / project calls in the consumer. Rejected for v1; the
single call is enough surface.
