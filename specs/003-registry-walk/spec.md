# Feature Specification: Upstream metadata fetch + chain sanity-check

**Feature Branch**: `003-registry-walk`
**Created**: 2026-05-05
**Status**: Draft
**Input**: User description: "On-chain registry NFT walk: parse inline datum, project to RegistryView, replace --registry PATH with --registry-utxo or --registry-policy"

> **Scope correction**: the original framing called for walking the
> registry NFT on-chain to recover all of `RegistryView`. Upstream
> inspection
> ([`lib/registry.ak`](https://github.com/pragma-org/amaru-treasury/blob/main/lib/registry.ak),
> [`journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json))
> showed that the `ScriptHashRegistry` inline datum carries only
> two script credentials, and the per-scope `*DeployedAt` UTxOs +
> owner key hashes live in upstream's git-versioned
> `metadata.json` — not on chain. The revised approach is "fetch
> upstream's `metadata.json` at a pinned commit, sanity-check
> against chain, project to `RegistryView`". See
> [issue #30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30)
> for the full reframing.

Tracking issue: [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30).
Unblocks: [PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Wizard refuses to operate on stale references (Priority: P1)

An operator runs `swap-wizard`; the upstream `metadata.json`
indicates a treasury script reference UTxO that has since been
consumed (re-deployed). The wizard MUST detect this and abort
before producing any `intent.json`.

**Why this priority**: The reason #30 exists. Stale references in
a signed-and-submitted treasury tx is the exact failure we need to
make impossible.

**Independent Test**: Stub a `Provider IO` that returns "spent" for
the `treasury_script.deployed_at` of the requested scope. Run the
resolver. Assert it returns `Left ChainVerificationError` and
writes nothing.

**Acceptance Scenarios**:

1. **Given** a metadata snapshot whose `deployed_at` UTxOs are all
   unspent on chain, **When** the wizard runs, **Then** it produces
   a valid `intent.json`.
2. **Given** the same metadata, but the
   `treasury_script.deployed_at` for the requested scope is now
   spent, **When** the wizard runs, **Then** it exits non-zero with
   a typed `ChainVerificationError` and does NOT write the file.
3. **Given** the same metadata, but the `scope_owners` UTxO is
   spent, **When** the wizard runs, **Then** same outcome.

---

### User Story 2 - Pinned-commit metadata fetch (Priority: P1)

The wizard reads `metadata.json` from
`https://raw.githubusercontent.com/pragma-org/amaru-treasury/<sha>/journal/2026/metadata.json`.
The default commit SHA is baked into the binary at build time;
overriding requires `--metadata-commit <sha>`. There is no path
that reads metadata from the local filesystem.

**Why this priority**: Removes the file-as-input footgun PR #28
introduced. The default pin makes "out of the box" usage track a
known-good upstream snapshot; the override lets operators advance
to a newer commit when upstream merges changes.

**Independent Test**: Run the wizard with `--metadata-commit
<known-bad-sha>` against an HTTP server that returns 404; assert
exit-3 with `MetadataFetchError`. Run with the default commit
against a stub server that returns the checked-in fixture; assert
the resolver builds `RegistryView` whose fields match the fixture.

**Acceptance Scenarios**:

1. **Given** a network with HTTP access, **When** the wizard runs
   with the default pin, **Then** it fetches successfully and
   proceeds.
2. **Given** the network is offline, **When** the wizard runs,
   **Then** it exits non-zero with `MetadataFetchError`.
3. **Given** `--metadata-commit deadbeef` (nonexistent), **When**
   the wizard runs, **Then** the upstream returns 404 and the
   wizard exits non-zero.

---

### User Story 3 - Upstream pin advances are code-review events (Priority: P2)

The default `metadata.json` commit pin lives in source code as a
constant. Updating it requires a PR.

**Why this priority**: Treats the pin as part of the binary's
attack surface. A fresh release of `amaru-treasury-tx` always
ships with a specific, audit-trailed snapshot.

**Independent Test**: Grep for `defaultUpstreamCommit` in the
source tree; verify it is a concrete 40-char hex SHA, not a tag
or branch name.

**Acceptance Scenarios**:

1. **Given** the source tree, **When** anyone tries to advance the
   pin, **Then** the change is visible in the diff and reviewable.

---

### Edge Cases

- The HTTP fetch returns a body that does not parse as the
  expected schema → typed `MetadataFetchError SchemaMismatch`.
- The upstream commit exists but the schema has shifted (new
  required field, renamed key) → same.
- A `deployed_at` UTxO has been spent and re-deployed at a
  different TxIn → wizard aborts (we do not auto-discover the new
  TxIn; that's an upstream-PR-followed-by-pin-bump event).
- Network partial reachability (DNS fine, HTTPS times out) →
  typed error, not a hang.
- The configured backend is offline → resolver still aborts at the
  chain-sanity step, not silently.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST fetch `metadata.json` from
  `https://raw.githubusercontent.com/pragma-org/amaru-treasury/<sha>/journal/2026/metadata.json`
  at runtime.
- **FR-002**: System MUST default the commit SHA to a constant
  baked into the binary (`defaultUpstreamCommit`).
- **FR-003**: System MUST accept `--metadata-commit <sha>` to
  override the default.
- **FR-004**: System MUST NOT accept a local-file path for the
  metadata input.
- **FR-005**: System MUST verify, before producing any output,
  that every TxIn referenced by the metadata (`scope_owners` and
  every per-scope `*.deployed_at`) is currently unspent.
- **FR-006**: On any verification failure, System MUST exit
  non-zero with a typed error and write nothing.
- **FR-007**: System MUST project the verified metadata into the
  existing `RegistryView` shape that
  `Amaru.Treasury.Tx.SwapWizard.resolveWizardEnv` already
  consumes.
- **FR-008**: System MUST drop the `--registry PATH` CLI flag.
- **FR-009**: System MUST drop the
  `test/fixtures/swap-wizard/registry.example.json` fixture and
  any documentation that points at it.
- **FR-010**: The `defaultUpstreamCommit` value MUST be a
  concrete 40-char hex SHA (no branches, no tags).

### Key Entities

- **UpstreamMetadata**: Haskell mirror of upstream's
  `metadata.json` schema (top-level `scope_owners` plus
  `treasuries.<scope>` records).
- **MetadataFetchError**: HTTP/parse failure modes.
- **ChainVerificationError**: per-TxIn "this UTxO is no longer
  unspent" failure mode.
- **defaultUpstreamCommit**: pinned SHA, single source of truth
  for the binary's view of the registry.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of wizard runs that produce `intent.json` had
  every metadata-referenced TxIn confirmed unspent on chain at the
  time of the run.
- **SC-002**: The wizard cannot be invoked with a local-file
  metadata input.
- **SC-003**: Advancing `defaultUpstreamCommit` requires a PR; the
  diff shows the SHA delta.
- **SC-004**: PR #28 becomes mergeable on top of this branch with
  no further safety changes.

## Assumptions

- Upstream's `metadata.json` schema is stable across the commit
  pins we support; schema breaks are caught by FromJSON failures
  and surface as `MetadataFetchError`.
- The local `Provider IO` is reachable. If the operator can't see
  chain state, they shouldn't be producing treasury txs at all,
  and the wizard refusing to run is correct.
- HTTPS to GitHub raw is acceptable. Air-gapped operation is out
  of scope for v1; if needed, a future flag could accept a
  `--metadata-snapshot <path>` *plus* a hash assertion.
- The existing `Amaru.Treasury.Tx.SwapWizard.RegistryView` shape
  is the target. The on-branch wizard from PR #28 will rebase on
  top of this work.
