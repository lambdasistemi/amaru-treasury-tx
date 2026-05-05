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
Upstream dependency:
[lambdasistemi/cardano-node-clients#128](https://github.com/lambdasistemi/cardano-node-clients/pull/128)
closed
[lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126)
with Provider acquired query sessions.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Wizard rejects every kind of metadata tampering or staleness (Priority: P1)

The wizard is given a local `metadata.json` file. The wizard
reads it but treats every claim as untrusted. For each field, it
cross-checks against an on-chain anchor or recomputes the value
from build-time constants. Any mismatch aborts before any output.

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

### User Story 2 - Operator supplies a local metadata snapshot (Priority: P1)

The wizard reads `metadata.json` from a local path supplied by
the operator. The file is only a hint: every claim is still
verified against chain before any downstream value is used.

**Why this priority**: This keeps the first implementation small
and auditable. URL/default fetch support is an ergonomic
refinement for a later request, not a safety requirement.

**Independent Test**: Run the wizard against the checked-in
local fixture and a network stub returning matching anchors;
assert the verified projection is produced.

**Acceptance Scenarios**:

1. **Given** `--metadata /tmp/metadata.json`, **When** the
   wizard runs, **Then** the file is loaded; verification
   proceeds normally.

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

- The metadata file is missing or unreadable → typed
  `MetadataReadError`. The wizard does NOT silently fall back to
  a different source.
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
- **FR-002**: System MUST source `metadata.json` from a local
  operator-supplied `--metadata <path>` file.
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
  currently unspent on chain. For `treasury_script.deployed_at`
  and `permissions_script.deployed_at` the named UTxO MUST
  carry the verified script hash as its reference script. For
  `registry_script.deployed_at` the UTxO IS the per-scope
  registry NFT location (inline `ScriptHashRegistry` datum, no
  reference script); System MUST verify the UTxO carries the
  derived registry NFT and parse the datum to extract the
  treasury script credential.
- **FR-007**: On any verification failure, System MUST exit
  non-zero with a typed error naming the offending field, and
  write no output.
- **FR-008**: The two seed `OutputReference`s and the compiled
  Plutus blobs MUST be pinned at build time to a specific
  upstream commit.
- **FR-009**: System MUST drop the `--registry PATH` flag
  introduced on PR #28.
- **FR-010**: `Provider IO` MUST expose an acquired query
  session with a batched-by-TxIn handle query:
  `queryUTxOByTxInH :: Set TxIn -> m (Map TxIn TxOut)`.
- **FR-011**: The chain-side verification MUST issue exactly
  one LSQ-backed query (`queryUTxOByTxInH`) inside one acquired
  Provider session, over `scope_owners` ∪ each requested scope's
  three `*.deployed_at` TxIns. No script-address derivation is
  required for the query, removing a class of bug where a wrong
  stake-reference convention silently returns empty UTxOs.
- **FR-012**: System MUST refuse a verification request with
  an empty scope set rather than silently sweep the entire
  metadata; callers explicitly opt into a full sweep by passing
  `Set.fromList allScopeIds`.

### Key Entities

- **UpstreamMetadata**: parsed mirror of upstream's
  `metadata.json` schema. Untrusted at construction.
- **VerifiedRegistry**: the post-verification view; only
  populated if every claim cross-checked against an anchor or
  derivation.
- **AnchorMismatch**: typed error tagged with the
  field name + scope.
- **MetadataReadError**: local file read failure mode (still
  typed, still loud, and distinct from metadata parse failure).
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
- **SC-003**: A wizard run completes with one acquired
  Provider session and exactly one LSQ-backed query against
  that snapshot (FR-011).
- **SC-004**: Advancing build-time pins requires a PR; the diff
  shows the SHA / seed / blob delta.
- **SC-005**: PR #28 rebases on top of this and merges with no
  further safety changes.

## Security model

### Trust roots

The verifier's safety derives from exactly two trust roots, both
local to this repository:

1. **Build-time pinned constants**: the two seed
   `OutputReference`s (`scopesSeedTxIdHex`, `registrySeedTxIdHex`)
   and the four compiled Plutus blobs (`scopes`,
   `treasury_registry`, `permissions`, `treasury`) embedded
   from `assets/plutus/*.cbor`. These are reviewed in the PR
   that advances the upstream pin.
2. **The on-chain ledger** observed through a local `cardano-node`
   socket. The verifier never trusts a remote indexer, an HTTP
   endpoint, or the operator's filesystem outside of the metadata
   hint.

`metadata.json` is **not** a trust root. Its content is parsed,
every field is cross-checked against an anchor (chain or
build-time derivation), and an unverifiable field aborts the
run.

### What the verifier protects against

- **Stale references**: a `*.deployed_at` TxIn that points at a
  spent UTxO fails the chain check.
- **Tampered hashes**: any of `treasury_script.hash`,
  `registry_script.hash`, `permissions_script.hash`, `address`,
  `owner` disagreeing with the on-chain anchor (NFT datum) or
  the build-time derivation aborts.
- **Substituted UTxOs**: a `*.deployed_at` TxIn that points at a
  UTxO not carrying the expected NFT (registry case) or not
  carrying the expected reference script (treasury / permissions
  case) aborts.
- **Wrong-scope swap**: per-scope verification is keyed on
  `ScopeId`; a metadata file describing the wrong scope produces
  a typed error rather than silently substituting a different
  treasury.

### What the verifier explicitly does NOT protect against

- **Compromised build-time pin**: if the upstream commit
  referenced in `assets/plutus/README.md` and
  `Amaru.Treasury.Registry.Constants` carries a malicious blob,
  the verifier will accept it. Mitigation: the pin advances by
  PR; the diff is small and reviewable.
- **Compromised local `cardano-node`**: a node serving forged
  ledger state to LSQ would let the verifier accept tampered
  metadata. Mitigation: run a node you control; verify it is
  in sync.
- **Race vs. mempool**: a `*.deployed_at` UTxO being consumed
  in flight after our LSQ acquire and before the operator
  signs+submits the produced intent. The next run will fail;
  partial output is never written. Acceptable.
- **Off-chain wizard inputs** (wallet TxIn, swap parameters,
  rationale text) — those are operator-supplied and not part
  of the registry walk's safety scope. PR #28 owns their
  validation.

### Failure mode

The verifier is **fail-closed**: on any anchor mismatch, spent
UTxO, ambiguous match, parse failure, or chain query error it
returns a typed `RegistryWalkError` and the caller writes no
output. There is no "best-effort" path. Operators see a typed
diagnostic naming the offending field (e.g.
`AnchorMismatch "treasury_script.deployed_at.metadata"
(Just CoreDevelopment) <expected> <got>`).

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
- Provider acquired query sessions from
  [lambdasistemi/cardano-node-clients#128](https://github.com/lambdasistemi/cardano-node-clients/pull/128)
  are available to keep the registry walk's chain reads on one
  acquired ledger snapshot.
- Fetching metadata over HTTP(S) or from a baked-in default URL
  is deferred until there is an explicit product request for it.
