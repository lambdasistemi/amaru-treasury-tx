# Feature Specification: On-chain anchor verification for the registry walk

**Feature Branch**: `003-registry-walk`
**Created**: 2026-05-05
**Status**: Draft
**Input**: User description: "On-chain registry NFT walk: parse inline datum, project to RegistryView, replace --registry PATH with --registry-utxo or --registry-policy"

> **Two scope corrections recorded as research-driven decisions** —
> see [research.md R1](./research.md). The accepted scope is
> "verify each registry field against an on-chain anchor", not
> "parse the registry datum" (rejected) and not "pin metadata at a
> SHA + check unspent" (rejected as strictly weaker). The full
> rationale is in the issue:
> [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30).

Tracking issue: [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30).
Unblocks: [PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28).
Upstream follow-up: [lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126)
(LSQ single-Acquired multi-query session — a v2 atomicity
enhancement, not a v1 blocker).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Wizard rejects every kind of metadata tampering or staleness (Priority: P1)

The wizard is given a `metadata.json` (from any source — default
URL, `--metadata-url`, `--metadata-file`). The wizard reads it
but treats every claim as untrusted. For each field, it
cross-checks against an on-chain anchor or recomputes the value
from build-time constants. Any mismatch aborts before any
output.

**Why this priority**: This is the safety property #30 exists
for. Tens of millions of ADA flow through the wizard's output;
trusting an off-chain file even at "current" content is a
footgun.

**Independent Test**: For each verifiable field, a unit test
constructs a metadata snapshot whose claim differs from the
stub-Provider's chain anchor. The verifier MUST emit a typed
error naming the offending field, and produce no JSON output.

**Acceptance Scenarios**:

1. **Given** a metadata snapshot whose `treasuries[scope].owner`
   does not match the corresponding entry in the on-chain
   `Scopes` NFT datum, **When** the wizard runs, **Then** it
   emits `AnchorMismatch "owner" scope` and writes nothing.
2. Same for `treasuries[scope].treasury_script.hash` vs the
   on-chain `ScriptHashRegistry` datum's `treasury` credential.
3. Same for `treasuries[scope].registry_script.hash` vs the
   locally re-derived `treasury_registry(seed, scope)` policy.
4. Same for `treasuries[scope].permissions_script.hash` vs the
   locally re-derived `permissions(scopes_nft_policy, scope)`
   hash.
5. Same for `treasuries[scope].address` vs the bech32 of the
   verified `treasury_script.hash` for the network.
6. **Given** a metadata snapshot whose `*.deployed_at` UTxO is
   no longer unspent (consumed by a re-deployment), **When** the
   wizard runs, **Then** it emits
   `AnchorMismatch "deployed_at" scope` and writes nothing.
7. **Given** a metadata snapshot whose `*.deployed_at` UTxO is
   unspent but does NOT carry the verified script hash as its
   reference script, **When** the wizard runs, **Then** same
   outcome.

---

### User Story 2 - Metadata source is interchangeable (Priority: P1)

The wizard can read `metadata.json` from a default URL, an
operator-supplied URL, or an operator-supplied file path. None
of these is treated as more trustworthy than the others — every
claim is verified against chain regardless. The default URL is
upstream's raw `main` for `pragma-org/amaru-treasury/journal/2026/metadata.json`.

**Why this priority**: Removes the "metadata file is dangerous"
framing entirely. Once verification is field-by-field, the
source doesn't matter for safety.

**Independent Test**: Run the wizard three ways: against a stub
HTTP server that serves the fixture (URL mode), against a local
file (path mode), and against the bake-in-default URL with a
network stub returning the same fixture. All three produce
byte-equal verified `RegistryView` projections.

**Acceptance Scenarios**:

1. **Given** `--metadata-file /tmp/metadata.json`, **When** the
   wizard runs, **Then** the file is loaded; verification
   proceeds normally.
2. **Given** `--metadata-url https://example.com/metadata.json`,
   **When** the wizard runs, **Then** the URL is fetched;
   verification proceeds normally.
3. **Given** neither flag, **When** the wizard runs, **Then**
   the default upstream URL is fetched; verification proceeds
   normally.

---

### User Story 3 - Build-time constants are auditable (Priority: P2)

The Plutus blobs and the two seed UTxOs that drive
script-hash derivation are pinned to a specific upstream commit
at build time and committed to the repo (or pulled by Nix from
a `flake.lock`-pinned input). Advancing them is one PR.

**Why this priority**: These are the actual trust roots. Wrong
seed or wrong blob → wrong derived script hashes → the verifier
either rejects everything (loud failure) or, worse, accepts a
malicious metadata claim that happens to match the wrong
derivation. Pinning makes "what's in this binary" diff-visible.

**Independent Test**: Grep the source tree for
`scopesSeedOutputReference` and `registrySeedOutputReference`
constants; confirm they are 64-char hex TxIds with explicit
`#0` indices, and that their values match upstream's
`aiken.toml` at the pinned commit. Confirm the Plutus blob
embedding sources point to that same commit.

**Acceptance Scenarios**:

1. **Given** the source tree, **When** anyone tries to advance
   the seeds or the blobs, **Then** the diff shows the change
   and is reviewable.

---

### Edge Cases

- The metadata-source HTTP fetch returns 404 / times out / fails
  TLS → typed `MetadataFetchError`. The wizard does NOT silently
  fall back to a different source.
- The metadata is correct but the chain has a re-deployment in
  flight (one `deployed_at` is being consumed in the mempool):
  the verifier sees the UTxO unspent, the wizard runs; the next
  run fails. This is acceptable.
- Multiple UTxOs at a script address satisfy the NFT criterion
  (token policy + asset name): abort with a typed error; the
  trap validators forbid this in normal operation.
- The configured `Provider IO` is offline → typed
  `ChainQueryError`; resolver fails closed.
- The metadata claims a scope we don't know about: ignore (we
  only verify the ones we resolve for the current swap).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST treat `metadata.json` content as
  untrusted. Every claim MUST be verified against an on-chain
  anchor or recomputed from build-time constants.
- **FR-002**: System MUST source `metadata.json` from one of:
  default upstream URL, `--metadata-url <url>`, or
  `--metadata-file <path>`. Exactly one source per run; flags
  are mutually exclusive.
- **FR-003**: System MUST verify scope-owner key hashes against
  the on-chain `Scopes` NFT inline datum.
- **FR-004**: System MUST verify per-scope treasury script
  hashes against the on-chain `ScriptHashRegistry` inline datum
  of the per-scope registry NFT.
- **FR-005**: System MUST recompute the per-scope registry
  policy id and the per-scope permissions script hash from
  build-time-pinned Plutus blobs + seeds, and reject metadata
  claims that disagree.
- **FR-006**: System MUST verify each `*.deployed_at` TxIn is
  currently unspent on chain AND that the named UTxO carries
  the verified script hash as its reference script.
- **FR-007**: On any verification failure, System MUST exit
  non-zero with a typed error naming the offending field, and
  write no output.
- **FR-008**: The two seed `OutputReference`s and the compiled
  Plutus blobs MUST be pinned at build time to a specific
  upstream commit.
- **FR-009**: System MUST drop the `--registry PATH` flag
  introduced on PR #28.
- **FR-010**: `Provider IO` MUST gain a batched address-set
  query: `queryUTxOsAt :: Set Addr -> m (Map Addr [...])`.
- **FR-011**: The chain-side verification MUST issue at most two
  LSQ round-trips against the node (one batched address query +
  one batched TxIn query).

### Key Entities

- **UpstreamMetadata**: parsed mirror of upstream's
  `metadata.json` schema. Untrusted at construction.
- **VerifiedRegistry**: the post-verification view; only
  populated if every claim cross-checked against an anchor or
  derivation.
- **AnchorMismatch**: typed error tagged with the
  field name + scope.
- **MetadataFetchError**: HTTP/parse failure mode (still typed,
  still loud, but does not affect trust — even if the fetch
  succeeded, content is verified).
- **Build-time constants**: `scopesSeedOutputReference`,
  `registrySeedOutputReference`, `scopesTokenName`,
  `registryTokenName`, `treasuryExpiration`,
  `payoutUpperbound`, plus the Plutus blob byte-strings.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of fields the wizard consumes from
  `metadata.json` are either anchored on chain (and verified) or
  derived from build-time constants (and recomputed).
- **SC-002**: Tampering with any verifiable field in
  `metadata.json` is detected by the unit tests.
- **SC-003**: A wizard run completes with at most two LSQ
  round-trips against the node (FR-011).
- **SC-004**: Advancing build-time pins requires a PR; the diff
  shows the SHA / seed / blob delta.
- **SC-005**: PR #28 rebases on top of this and merges with no
  further safety changes.

## Assumptions

- The upstream Aiken contracts at the pinned commit are correct
  (audited; the existing
  [audit report](https://github.com/pragma-org/amaru-treasury/blob/main/audit-report-2025-08-05-txpipe-shop.pdf)
  applies). We do not re-audit; we just bind to the same blobs.
- The trap validators (`scopes`, `treasury_registry`) preserve
  the "exactly one NFT-bearing UTxO at the script address"
  invariant. If two were ever observed, that's an upstream
  audit failure and the wizard refusing to run is correct.
- The local `Provider IO` is reachable. Offline operation is
  not supported in v1.
- Cross-call LSQ atomicity is acceptable to defer to upstream
  ([lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126));
  the per-call atomicity LSQ already provides is sufficient for
  v1 because chain advance during a few hundred ms is rare and
  next-run verification catches any state torn read.
