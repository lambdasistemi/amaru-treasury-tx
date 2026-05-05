# Phase 0 Research: On-chain anchor verification

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

## R1. Where the trust actually lives

**Decision**: Trust is **on chain plus build-time constants**.
Trust is NOT in `metadata.json`. The metadata is a hint —
useful, but verified field-by-field.

**Rationale** (the long version that produced this scope after
two rejected framings):

- **Rejected v1**: walk the registry NFT inline datum on chain
  to recover everything. Doesn't work — the
  `ScriptHashRegistry` datum carries only `treasury` + `vendor`
  script credentials. The `*DeployedAt` UTxOs and scope-owner
  keys are not on chain.
  ([`treasury-contracts/lib/types.ak`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/8a3183c929be57886214624b45ee0c43a0c19277/lib/types.ak))
- **Rejected v2**: pin upstream's `metadata.json` at a SHA,
  fetch over HTTPS, sanity-check that `deployed_at` is unspent.
  Strictly weaker than per-field verification because the
  metadata's *content* is still trusted. A tampered metadata
  with valid (but wrong-for-the-script) deployed_at refs would
  pass the unspent check.
- **Accepted**: per-field anchor verification. Each field in
  metadata is either (a) anchored on chain (Scopes NFT datum,
  registry NFT datum), (b) derivable from build-time constants
  + chain anchors (registry policy id, permissions script
  hash, treasury address), or (c) an operator-supplied hint
  for which we still verify the *referenced UTxO matches the
  derived/anchored hash* (`*_deployed_at`).

The upstream audit
([txpipe-shop, 2025-08-05](https://github.com/pragma-org/amaru-treasury/blob/main/audit-report-2025-08-05-txpipe-shop.pdf))
applies to the on-chain contracts; we bind to the same
audited blobs.

## R2. The two seed UTxOs are the trust roots

**Decision**: Bake `scopes_seed_output_reference` and
`registry_seed_output_reference` (from upstream
[`aiken.toml`](https://github.com/pragma-org/amaru-treasury/blob/main/aiken.toml))
as build-time constants in the binary. Wrong values → wrong
NFT policy ids → verification rejects everything.

**Rationale**: These two TxIns parameterise `scopes(seed)` and
`treasury_registry(seed, scope)`, which determine the policy
ids of the Scopes NFT and per-scope registry NFTs. Without
them we cannot know "which NFT is real". They are upstream's
sole bootstrap input; pinning them is equivalent to pinning
the deployed contract instance.

**Alternatives considered**:
- Take them as CLI flags. Rejected: the user could mis-paste
  and send the wizard searching for an attacker-controlled
  NFT. They belong in code review, not at runtime.
- Read them from `metadata.json`. Rejected: the metadata is
  untrusted by FR-001.

## R3. The Plutus blobs are the second trust root

**Decision**: Embed the compiled Plutus validator blobs from
upstream's `plutus.json` for `scopes`, `treasury_registry`,
`permissions`, and the SundaeSwap treasury validator. Pin them
to the same commit as the seeds. Update via PR.

**Rationale**: We need to compute parameter-applied script
hashes locally. The validators are upstream's compiled code;
we don't reimplement them. Different blob → different hash →
verification mismatch.

**Alternatives considered**:
- Trust an "is this validator at this script address?" check
  on chain instead of recomputing the hash. Rejected: that's
  basically a tautology; we'd still trust whatever metadata
  said the address was.
- Lazy-compute (don't embed; download from upstream at
  runtime). Rejected: same trust model as the metadata —
  unacceptable for a script root.

## R4. Anchor topology — what's verifiable how

| Metadata field | Verification |
|---|---|
| `treasuries[scope].owner` | On-chain Scopes NFT datum at `scope_owners` |
| `treasuries[scope].treasury_script.hash` | On-chain `ScriptHashRegistry.treasury` at the per-scope registry NFT |
| `treasuries[scope].registry_script.hash` | Recomputed: `policyId(treasury_registry(registry_seed, scope))` |
| `treasuries[scope].permissions_script.hash` | Recomputed: `scriptHash(permissions(scopes_nft_policy, scope))` |
| `treasuries[scope].address` | Bech32 of verified `treasury_script.hash` for the network |
| `treasuries[scope].*.deployed_at` | UTxO at TxIn must be unspent AND its reference script hash must equal the verified script hash for that field |
| `scope_owners` (TxIn) | UTxO at TxIn must be unspent AND must hold the Scopes NFT (policy = `policyId(scopes(scopes_seed))`, asset = `"amaru 2026 scopes"`) |

Per-scope registry NFT discovery: derive
`treasury_registry(seed, scope)` script hash → derive bech32
script address → `queryUTxOs <addr>` → filter for the unique
UTxO holding the `(derived_policy_id, "REGISTRY")` token.

## R5. The metadata source is local-only for v1

**Decision**: Read metadata from a local path supplied as
`--metadata <path>`.

**Rationale**: After per-field verification, the source's
trustworthiness is irrelevant to safety, but URL fetching and
default-source selection add implementation and UX surface that
is not needed for the first request. Operators can pre-fetch or
edit a local snapshot, and every field is still checked against
chain before use.

**Deferred**:
- Default upstream URL.
- URL-sourced metadata.
- Mirror/source selection.

## R6. LSQ query shape

**Decision**: One acquired Provider session per wizard run,
containing two LSQ-backed queries:

1. `queryUTxOsAtH :: Set Addr` over the scopes-validator
   address plus each requested scope's registry-validator
   address → all NFT UTxOs in one shot.
2. `queryUTxOByTxInH :: Set TxIn` over all `*_deployed_at`
   refs → all reference UTxOs in one shot.

**Rationale**: LSQ's `GetUTxOByAddress` and `GetUTxOByTxIn`
both accept sets natively. `cardano-node-clients#128` adds
`Provider.withAcquired` and acquired `QueryHandle` selectors,
so both queries are evaluated against one acquired ledger
snapshot. That closes the atomicity follow-up tracked in
`cardano-node-clients#126`.

## R7. Permissions script parameterisation

**Decision**: `permissions(scopes_nft_policy, scope)`. Both
arguments are deterministic from build-time constants once we
have the Scopes NFT policy. So the permissions script hash is
fully recomputable; no on-chain anchor is needed beyond the
Scopes NFT datum (which gives us the policy via the seed +
blob bake-in).

**Rationale**: Reading
[`validators/permissions.ak`](https://github.com/pragma-org/amaru-treasury/blob/main/validators/permissions.ak):
the validator takes `(scopes_nft: PolicyId, scope: Scope)`. No
runtime state. Once the Scopes NFT policy is known (which we
re-derive locally from the seed + blob), the permissions hash
falls out of one parameter application + hash.

## R8. Test strategy

**Decision**:

- Pure: parameter-application + hash test against checked-in
  expected values for at least one scope.
- Pure: metadata-projection test against a fixture
  metadata.json + a fixture set of "anchor results" (script
  hashes, owner keys) — assert the verified projection.
- Stub-Provider integration: feed the verifier a stubbed
  Provider that returns the on-chain anchors that *match* the
  fixture; assert OK.
- Stub-Provider mutation tests: for each verifiable field,
  flip one byte in the metadata or in the chain stub; assert
  the matching `AnchorMismatch` constructor.

**Rationale**: Constitution V (test-first with golden
fixtures); SC-002. The mutation table is the safety property
made executable.
