# Feature Specification: `reorganize-wizard` runner + DevNet guard

**Feature Branch**: `187-reorganize-wizard-runner`
**Created**: 2026-05-22
**Status**: Draft (Q-001-spec-ready)
**GitHub Issue**: [#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187)
**Pull Request**: [#198](https://github.com/lambdasistemi/amaru-treasury-tx/pull/198) (draft)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189) — reorganize transaction end-to-end
**Feature Anchor**: [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
**Depends on (merged on `main`)**:

- [#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185) — `ReorganizeIntent` + `runReorganizeBuild` library core (merged at `da9d65b5`)
- [#186](https://github.com/lambdasistemi/amaru-treasury-tx/issues/186) — `reorganize-wizard` parser scaffold + stub runner (merged at `1d99cd3b`)

**Sibling children (later, depend on this slice merging first)**:

- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87) — DevNet smoke (live CLI reorganize)
- [#188](https://github.com/lambdasistemi/amaru-treasury-tx/issues/188) — docs page + asciinema cast

**Input**: Replace the `runReorganizeWizardEither` Slice-1 TODO stub
(currently `Left ReorganizeTodoSliceC` after pre-flight passes) with a
production runner body. The runner reads the registry / metadata
artifact, queries the live chain for the treasury UTxO set + the
wallet UTxO set, samples the upper-bound slot, encodes one bare
`SomeTreasuryIntent` JSON to `--out`, and surfaces a typed
`ReorganizeError` on every failure path. The DevNet fail-closed
guard is reaffirmed: `--network` other than `devnet` is rejected
before any chain query (already enforced as `ReorganizeNonDevnetNetwork`
in #186; this slice extends the runner without weakening the guard).

This slice mirrors the resolver-driven runner pattern shipped by the
sibling `stake-reward-init-wizard` family
(`Amaru.Treasury.Cli.StakeRewardInitWizard.runScriptAccount` and
`Amaru.Treasury.Tx.StakeRewardInitWizard.resolveStakeRewardInitScriptAccount`),
which is itself the resolver pattern shipped by
`registry-init-wizard` before it. After this slice an operator can run
the documented command against a DevNet and observe a bare
`SomeTreasuryIntent` JSON ready for `tx-build --intent`.

> **Scope framing:** this slice is the **CLI runner body** only. No
> DevNet smoke, no docs, no asciinema cast, no changes to the
> library-core reorganize build path (already shipped in #185), no
> changes to the parser surface (already shipped in #186 — minor
> required additions, if any, fall into Q-001-A below). After this
> slice an operator running
> `amaru-treasury-tx reorganize-wizard --network devnet …` observes
> a bare `SomeTreasuryIntent` JSON at the `--out` path. The live
> DevNet smoke (#87) and operator-facing docs/cast (#188) follow.

## Upstream parity reference

The upstream bash
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
chains seven phases. #186 shipped the parser. #187 wires the runner
for every phase except the construction step (already in #185) and
the smoke step (#87).

| Bash phase | This slice covers? | Notes |
|---|---|---|
| `parse_cli` / opt-parsing | no — shipped by #186 | parser + typed answers already in `Cli/ReorganizeWizard.hs` |
| `load_metadata` / `load_treasury_config` | **yes** | reuse `Amaru.Treasury.Metadata.readMetadataFile`; index by `--scope` |
| `build_signers $metadata $scope` | **yes** | extract `smOwner` (scope-owner key hash) from metadata |
| `resolve_fuel` | **yes** | reuse `selectWallet` against the wallet-addr chain query; operator-typed `--funding-seed-txin` is the wallet UTxO (matches sibling pattern) |
| `select_treasury_utxos` | **yes** | query treasury address; "compress until full" iteration that returns ≥2 UTxOs or surfaces `ReorganizeInsufficientTreasuryUtxos` |
| `compute_validity_period` | **yes** | reuse `Cardano.Node.Client.Provider.queryUpperBoundSlot` (same `ValidityChoice` shape stake-reward-init uses) |
| `make_redeemer_reorganize` | no — already library (#185) | `Amaru.Treasury.Redeemer.reorganizeRedeemer` |
| `build_transaction` | no — already library (#185) | `Amaru.Treasury.Build.Reorganize.runReorganizeBuild` |
| intent JSON encode + write to `--out` | **yes** | reuse `encodeSomeTreasuryIntent`; envelope is `SomeTreasuryIntent SReorganize …` |

The runner-body boundary is therefore: **read metadata, query chain,
select treasury UTxOs, compute validity bound, encode the bare
`SomeTreasuryIntent` JSON, write it to `--out`, surface every failure
as a typed `ReorganizeError`**.

## User Scenarios & Testing

### User Story 1 — `reorganize-wizard --network devnet …` writes a `SomeTreasuryIntent` JSON to `--out` (Priority: P1)

**As an operator preparing a treasury reorganize transaction on a
local DevNet**, I run

```bash
amaru-treasury-tx reorganize-wizard \
  --network devnet \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --metadata journal/2026/metadata.json \
  --wallet-addr "$WALLET_BECH32" \
  --funding-seed-txin "$FUNDING_TXIN" \
  --scope core_development \
  --out /tmp/reorganize-intent.json
```

against a live DevNet and observe a bare `SomeTreasuryIntent` JSON at
`/tmp/reorganize-intent.json`. The file is the **same envelope shape**
that `decodeTreasuryIntent` accepts, so

```bash
amaru-treasury-tx tx-build --intent /tmp/reorganize-intent.json \
  --out reorganize.unsigned.cbor
```

immediately produces an unsigned Conway tx.

**Why this priority**: this IS the parent epic #189 P1 contract for
this child. The shipped runner is the operator-recovery proof; without
the runner the wizard binary only prints the TODO marker. Every other
child of #189 depends on this slice producing a real intent JSON.

**Independent Test**: drive the runner against a recorded DevNet
fixture (chain context + metadata fixture); assert (1) exit code is 0,
(2) the file at `--out` exists, (3) decoding it as
`SomeTreasuryIntent` round-trips through `decodeTreasuryIntent` ∘
`encodeSomeTreasuryIntent`, (4) the decoded intent carries the
`SReorganize` arm and its `ReorganizeInputs` payload references the
treasury UTxOs the fixture provided.

**Acceptance Scenarios**:

1. **Given** a DevNet with a metadata.json carrying the scope
   `core_development` and ≥2 treasury UTxOs at that scope's
   treasury address, **When** the wizard runs with valid flags
   pointing at that DevNet, **Then** the wizard writes a file at
   `--out` whose bytes parse as
   `SomeTreasuryIntent SReorganize <TreasuryIntent>` and whose
   `ReorganizeInputs.treasuryUtxos` contains the selected
   treasury UTxOs (in chain order), `ReorganizeInputs.walletUtxo`
   equals the operator-typed `--funding-seed-txin`, and
   `ReorganizeInputs.upperBound` is the resolver-supplied slot.
2. **Given** the file written in scenario 1, **When**
   `tx-build --intent <out>` runs against the same DevNet,
   **Then** the dispatcher (already wired by #185) produces an
   unsigned Conway tx. (This scenario is verified as part of #87's
   live DevNet smoke — included here for completeness; the
   runner-unit suite for #187 stops at the JSON round-trip.)

---

### User Story 2 — missing registry / metadata artifact surfaces typed error before chain query (Priority: P1)

**As an operator**, when I point `--metadata` at a path that does not
exist (typo in the run directory) or that fails to decode as
`TreasuryMetadata`, the wizard surfaces a typed `ReorganizeError` to
stderr and exits non-zero **before** querying the wallet, the treasury,
or the chain tip. The typed error is structurally inspectable from
the test suite (no stderr regex matching).

**Why this priority**: matches the
`StakeRewardInitRegistryReadError` shape every sibling wizard already
ships. Catches operator-input typos before opening a node socket; the
node socket is the next most expensive resource to acquire and a
late-stage failure dumps a confusing chain-client stack trace.

**Independent Test**: drive the runner with `--metadata
/tmp/nonexistent-187/metadata.json`, assert the typed
`ReorganizeMetadataReadError <raw IOException/decode message>` value
surfaces on the `Either` boundary, exit code is 2 (matching the
sibling pre-flight exit code).

**Acceptance Scenarios**:

1. **Given** the executable and `--metadata /tmp/<absent>/metadata.json`
   whose file is absent, **When** the wizard runs with otherwise
   valid flags, **Then** the wizard exits non-zero with stderr naming
   the typed `ReorganizeMetadataReadError` and a one-line message
   pointing at the missing path. No node socket is opened; no file
   is written to `--out`.
2. **Given** the executable and `--metadata <path>` pointing at a
   file that exists but does not decode as `TreasuryMetadata`
   (truncated JSON, missing required field), **When** the wizard
   runs with otherwise valid flags, **Then** the wizard exits
   non-zero with the same typed `ReorganizeMetadataReadError`
   carrying the aeson decode message.
3. **Given** the executable and `--metadata <path>` decoding fine
   but missing the scope named by `--scope` (e.g.
   `--scope ops_and_use_cases` against a one-scope fixture),
   **When** the wizard runs with otherwise valid flags, **Then** the
   wizard exits non-zero with a typed
   `ReorganizeScopeNotInMetadata <ScopeId>` error.

---

### User Story 3 — fewer than 2 treasury UTxOs surfaces typed `InsufficientTreasuryUtxos` error (Priority: P1)

**As an operator**, when I run reorganize against a DevNet where the
named scope's treasury address holds **0 or 1** UTxOs, the wizard
refuses to write an intent (because a reorganize with fewer than 2
inputs cannot perform a meaningful merge) and surfaces a typed
`ReorganizeInsufficientTreasuryUtxos` error with the count it
observed. Exit code 2 (pre-flight tier — distinguishes operator
configuration from runner-body failure).

**Why this priority**: a reorganize tx that merges 0 or 1 treasury
UTxO is a no-op that wastes a fuel UTxO; the parent invariant (#189)
calls this out as an early-failure boundary. The typed error
distinguishes "the chain state is too sparse for reorganize" from
"the runner body crashed" so the operator knows to wait for more
treasury inflows rather than re-run.

**Independent Test**: drive the runner against a recorded chain
fixture whose treasury-address query returns either zero rows or
exactly one row; assert the `Either` boundary yields
`Left (ReorganizeInsufficientTreasuryUtxos {observed = 0|1})` (exact
field/constructor shape settled in plan); exit code is 2; no `--out`
file is written.

**Acceptance Scenarios**:

1. **Given** a chain fixture whose treasury-address query returns
   zero UTxOs, **When** the wizard runs with otherwise valid flags,
   **Then** the wizard exits non-zero with
   `ReorganizeInsufficientTreasuryUtxos 0` on stderr; no `--out`
   file is written.
2. **Given** a chain fixture whose treasury-address query returns
   exactly one UTxO, **When** the wizard runs with otherwise valid
   flags, **Then** the wizard exits non-zero with
   `ReorganizeInsufficientTreasuryUtxos 1` on stderr; no `--out`
   file is written.
3. **Given** a chain fixture whose treasury-address query returns
   exactly two UTxOs, **When** the wizard runs with otherwise valid
   flags, **Then** the wizard succeeds (scenario 1 of User Story 1).
   The two-UTxO boundary is the minimum that yields a non-trivial
   merge.

---

### User Story 4 — `--network` other than `devnet` rejected before any chain query (Priority: P1)

**As an operator**, when I accidentally point `--network` at
`preprod` or `mainnet`, the wizard refuses to build the intent. The
runner pre-flight rejects any non-`devnet` value before opening a
node socket, querying the chain, or writing the `--out` file. This
guard already exists in #186's stub runner
(`ReorganizeNonDevnetNetwork`); #187 reaffirms it under the live
runner.

**Why this priority**: parent-epic carry-forward invariant. Without
network safety enforced before any work, an operator could build an
intent that references a mainnet treasury address and not discover
the mistake until later. The library-core reorganize build path
(already shipped in #185) does **not** re-validate the network — it
trusts the wizard's typed-environment output. Therefore the wizard
must fail closed.

**Independent Test**: invoke the wizard with `--network preprod` (or
`mainnet`, or `preview`), assert exit code is non-zero (2), stderr
names the typed `ReorganizeNonDevnetNetwork` error carrying the
offending network name, no chain query was attempted, no `--out`
file was written.

**Acceptance Scenarios**:

1. **Given** the executable, **When** the operator passes
   `--network preprod`, **Then** the wizard rejects before any
   chain query or file write; exits with code 2; stderr names
   `ReorganizeNonDevnetNetwork "preprod"`. (#186 already wires this;
   #187's runner extends it without weakening.)
2. **Given** the executable, **When** the operator passes
   `--network mainnet`, **Then** the wizard rejects identically with
   `ReorganizeNonDevnetNetwork "mainnet"`.
3. **Given** the executable, **When** the operator passes
   `--network devnet` and the chain fixture is healthy, **Then** the
   pre-flight accepts; the runner proceeds through metadata + chain
   queries; the intent JSON is written (User Story 1).

---

### User Story 5 — `decodeTreasuryIntent ∘ encodeSomeTreasuryIntent` round-trips the runner output (Priority: P2)

**As a developer**, the bytes written by the runner at `--out` must
round-trip cleanly through the library JSON codec; otherwise
`tx-build --intent` would silently fail on the operator's machine and
the failure would be invisible from this slice's unit suite.

**Why this priority**: secondary to the operator-visible behaviors
above, but the cheapest test that catches schema drift between the
runner's `ReorganizeInputs` builder and the library codec. Without
it, a subtle change to a field name (camelCase vs snake_case) ships
silently.

**Independent Test**: run the happy-path scenario (User Story 1
acceptance 1), read the written bytes, decode via
`Amaru.Treasury.IntentJSON.decodeTreasuryIntent`, assert the decoded
value equals the value the runner constructed in-memory before
encoding (modulo any documented normalization the codec performs).

**Acceptance Scenarios**:

1. **Given** the runner's happy path, **When** the test reads the
   `--out` bytes and decodes them via `decodeTreasuryIntent`,
   **Then** the decode succeeds and the round-tripped
   `SomeTreasuryIntent` carries the `SReorganize` arm equal (by
   `Eq` instance) to the runner's in-memory construction.

---

### Edge Cases

- **`--scope` value not in metadata.json** (e.g. `--scope
  contingency` against a fixture that only defines
  `core_development`): the parser accepts any value the
  `scopeFromText` reader accepts (open enum). The runner must
  surface a typed `ReorganizeScopeNotInMetadata` error before any
  chain query (User Story 2 scenario 3). The pre-flight ordering is:
  network guard → metadata read → scope lookup → chain queries.
- **`--node-socket` / `CARDANO_NODE_SOCKET_PATH` absent**: matches
  the sibling pattern in `runScriptAccount` — the runner aborts
  before opening the node backend with
  `--node-socket / CARDANO_NODE_SOCKET_PATH is required`. (#186's
  Slice-1 stub did not reach this code path; #187 inherits the
  shape from the sibling.)
- **`--funding-seed-txin` references a UTxO not present in the
  wallet-addr chain query**: the runner does NOT cross-check; it
  trusts the operator-typed seed and bakes it into the intent
  verbatim (matching the sibling stake-reward-init runner's stance
  — see `mkWalletScriptAccount` in
  `Amaru.Treasury.Tx.StakeRewardInitWizard`). Cross-step tx-body
  simulation is parked under the #156/#158/#159 non-goal posture.
- **`--validity-hours 0`**: the runner surfaces a typed
  `ReorganizeValidityHoursZero` error (mirrors
  `StakeRewardInitValidityHoursZero`).
- **`--validity-hours <n>` overshoots horizon**: the runner surfaces
  a typed `ReorganizeValidityOvershoot HorizonError` (mirrors the
  sibling).
- **Empty wallet at `--wallet-addr`** (chain query returns no UTxOs):
  the runner surfaces a typed `ReorganizeWalletShortfall` error
  (mirrors the sibling). Even though the operator-typed
  `--funding-seed-txin` overrides the wallet selection, the wallet
  shortfall is observable upstream — failing fast there gives a
  clearer error than "intent references a UTxO that does not
  exist".
- **`--metadata` carries no `owner` for the named scope** (only the
  `contingency` scope is allowed to omit `owner` per the
  `journal/2026/metadata.json` schema): the runner surfaces a typed
  `ReorganizeScopeOwnerMissing` error. Reorganize requires the
  scope-owner signer (`rgiScopeOwnerSigner` in `ReorganizeIntent`);
  a missing owner is unrecoverable.

## Requirements

### Functional Requirements

- **FR-001**: `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` MUST expose
  (in addition to the Slice-1 shape — see FR-001b):
  - `data ReorganizeResolverInput = ReorganizeResolverInput { … }`
    carrying every CLI-derived input the resolver needs before
    chain queries (network, wallet bech32, metadata path, scope,
    validity-hours);
  - `data ReorganizeResolverEnv m = ReorganizeResolverEnv { … }`
    record-of-functions abstracting the chain effects (wallet
    UTxO query, treasury UTxO query, upper-bound query, metadata
    read) so the unit suite can drive the resolver without a live
    node (mirrors `StakeRewardInitResolverEnv`);
  - `data ReorganizeEnv = ReorganizeEnv { … }` the resolved
    environment the pure translator consumes (network, upper-bound
    slot, parsed `TreasuryMetadata`, `ScopeMetadata` for the named
    scope, `WalletSelection`, the non-empty list of treasury UTxOs
    selected for merge);
  - `resolveReorganize :: Monad m => ReorganizeResolverEnv m ->
    ReorganizeResolverInput -> m (Either ReorganizeError
    ReorganizeEnv)` — the chain-side resolver;
  - `reorganizeToIntent :: ReorganizeEnv ->
    ReorganizeWizardAnswers -> Either ReorganizeError
    SomeTreasuryIntent` — the pure translator that emits a
    `SomeTreasuryIntent SReorganize` value.
- **FR-001b**: `ReorganizeError` (already shipped in #186 with four
  variants) MUST be extended with the runner-body variants. At
  minimum:
  - `ReorganizeMetadataReadError !String` (any failure reading or
    decoding the `--metadata` file);
  - `ReorganizeScopeNotInMetadata !ScopeId` (the named scope is
    absent from the parsed metadata);
  - `ReorganizeScopeOwnerMissing !ScopeId` (the named scope has
    `owner = null`; only contingency may omit `owner`, but
    contingency cannot reorganize);
  - `ReorganizeInsufficientTreasuryUtxos !Int` (the chain returned
    fewer than 2 treasury UTxOs for the scope's treasury address);
  - `ReorganizeWalletShortfall` (the wallet-addr chain query
    returned no UTxOs at all);
  - `ReorganizeValidityHoursZero` (`--validity-hours = Just 0`);
  - `ReorganizeValidityOvershoot !HorizonError` (`--validity-hours`
    overshoots the horizon);
  - one or more variants for ledger-field parse failures (treasury
    address bech32, owner key-hash hex, deployed-at TxIns,
    permissions reward account derivation). The plan picks the
    exact field-decomposition; the issue's AC says "typed error",
    not "one error per field".
  The Slice-1 `ReorganizeTodoSliceC` variant MUST be removed in
  this slice (it represents the stub that this slice replaces).
- **FR-002**: `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` MUST
  replace the `runReorganizeWizardEither` stub body (currently
  `pure (Left ReorganizeTodoSliceC)` after pre-flight passes) with
  a call into the new resolver + translator pipeline. The live
  runner MUST:
  1. perform the existing `--out` pre-flight (FR retained from
     #186);
  2. perform the existing network guard (FR retained from #186);
  3. require `--node-socket` / `CARDANO_NODE_SOCKET_PATH` (matches
     the sibling pattern; the stub did not need this);
  4. open the local node backend via
     `Amaru.Treasury.Backend.N2C.withLocalNodeBackend`;
  5. build the `ReorganizeResolverEnv` record-of-functions from
     `Cardano.Node.Client.Provider` (wallet flat query, upper-bound
     query, treasury-address flat query, metadata read);
  6. call `resolveReorganize`; on `Left`, exit with the typed
     error's mapped code;
  7. call `reorganizeToIntent`; on `Left`, exit with the typed
     error's mapped code;
  8. encode via `Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent`
     and write the bytes to `--out`;
  9. exit 0.
- **FR-003**: The runner MUST emit the intent JSON as the **bare
  `SomeTreasuryIntent` envelope** that `decodeTreasuryIntent`
  consumes — no wrapping object, no extra fields beyond what the
  envelope shape already carries. The bytes round-trip through the
  library codec (User Story 5).
- **FR-004**: The metadata-read step MUST reuse
  `Amaru.Treasury.Metadata.readMetadataFile` (or a thin
  IOException-catching wrapper if `readMetadataFile` throws on
  missing files — the resolver contract surfaces a
  `Left ReorganizeMetadataReadError` instead of an uncaught
  IOException, mirroring `readRegistrySafely` in
  `Cli/StakeRewardInitWizard.hs`).
- **FR-005**: The treasury-UTxO selection MUST use the chain query
  result at the scope's `smAddress` and return the selected
  UTxOs in chain order (sorted by TxId then index, matching
  upstream `select_treasury_utxos.sh`'s implicit ordering — see
  Q-001-D for the exact ordering pin). The "compress until full"
  iteration in `select_treasury_utxos.sh` collapses to "take all
  UTxOs available at the treasury address" for this slice (the
  upper bound on output count is the ledger's input-set
  cardinality; the wizard does not yet implement a configurable
  per-call cap — see Q-001-E).
- **FR-006**: The wallet-UTxO step MUST query the chain at
  `--wallet-addr`, run the selection helper (e.g.
  `Amaru.Treasury.Tx.SwapWizard.selectWallet`), and surface
  `ReorganizeWalletShortfall` on empty / shortfall. The
  operator-typed `--funding-seed-txin` is baked into
  `ReorganizeInputs.walletUtxo` verbatim — the wallet-addr
  selection result is informational (matches the sibling
  `mkWalletScriptAccount` pattern).
- **FR-007**: The upper-bound step MUST reuse
  `Cardano.Node.Client.Provider.queryUpperBoundSlot` with the same
  `ValidityChoice` semantics as the sibling resolver
  (`AutoLongest` when `--validity-hours = Nothing`, `ExactlyHours
  n` otherwise; `Just 0` short-circuits to
  `ReorganizeValidityHoursZero` before the query).
- **FR-008**: `Amaru.Treasury.Cli.ReorganizeWizard.exitCodeFor` MUST
  be extended to map every new `ReorganizeError` variant. The
  sibling exit-code convention applies:
  - exit `2` for pre-flight / configuration tier
    (`MetadataReadError`, `ScopeNotInMetadata`, `ScopeOwnerMissing`,
    `InsufficientTreasuryUtxos`, `WalletShortfall`,
    `ValidityHoursZero`, `ValidityOvershoot`, plus the existing
    `OutputParentMissing`, `OutputExistsNoForce`,
    `NonDevnetNetwork`);
  - exit `3` for runner-body-tier failure (any ledger-field parse
    failure in `reorganizeToIntent`).
  The plan finalizes which variant lives at which tier.
- **FR-009**: New runner tests under
  `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` MUST cover,
  at minimum, the four error User Stories (2, 3, 4) and the happy
  path (User Story 1) + JSON round-trip (User Story 5). The tests
  drive `resolveReorganize` + `reorganizeToIntent` via the
  mock-driven `ReorganizeResolverEnv` (no live node; mirrors the
  sibling spec).
- **FR-010**: `amaru-treasury-tx.cabal` MUST expose the new spec
  module (`Amaru.Treasury.Tx.ReorganizeWizardSpec` lives under
  `test-suite unit-tests` per the existing cabal stanza). No new
  library modules — the FR-001 additions land in the existing
  `Amaru.Treasury.Tx.ReorganizeWizard` and
  `Amaru.Treasury.Cli.ReorganizeWizard` modules.
- **FR-011**: `nix build .#checks.unit` MUST pass at HEAD. Every
  commit on `187-reorganize-wizard-runner` MUST pass `./gate.sh`
  (build + unit + golden + format + hlint + Conventional Commits
  + `Tasks:` trailer).
- **FR-012**: This slice MUST NOT touch
  `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`, or
  `lib/Amaru/Treasury/Build.hs` — those are owned by the
  already-merged #185 library core. The runner consumes the
  library codec (`encodeSomeTreasuryIntent`) and the metadata
  reader (`readMetadataFile`); it does not extend either.

### Non-Functional Requirements

- **NFR-001**: This slice introduces NO DevNet smoke. The smoke is
  owned by #87 and is gated on this slice merging first.
- **NFR-002**: This slice introduces NO README / `docs/...` changes
  and NO asciinema cast. The operator-facing doc page +
  `docs/assets/asciinema/reorganize.cast` are owned by #188
  (consistent with #186's deliverables note: the cast is recorded
  against a usable runner, which #187 ships, and recorded **in
  #188**).
- **NFR-003**: This slice introduces NO new dependencies in
  `amaru-treasury-tx.cabal`. The pieces it needs
  (`Amaru.Treasury.Metadata`, `Amaru.Treasury.Backend.N2C`,
  `Cardano.Node.Client.Provider`, `Amaru.Treasury.IntentJSON`)
  are all already in the library closure.
- **NFR-004**: Library + CLI-only behavior changes are bisect-safe.
  Every commit on the branch compiles; every commit's `./gate.sh`
  is green. The TODO marker `ReorganizeTodoSliceC` is removed in
  the same slice that replaces the stub body — there is no
  half-merged intermediate state where the stub variant exists
  alongside the runner variants.
- **NFR-005**: The runner pre-flight ordering MUST keep the cheap
  failures first, matching the existing #186 contract:
  network-string compare → `--out` parent-dir syscall →
  `--node-socket` env / CLI check → metadata file read → scope
  lookup → chain queries. No chain query precedes a configuration
  check.
- **NFR-006 (subcommand independence)**: the resolver does NOT
  branch on any sibling action's state. Reorganize is per-scope;
  the resolver consumes the named `--scope` only.

### Key Entities

- **`ReorganizeResolverInput`** (in
  `Amaru.Treasury.Tx.ReorganizeWizard`): CLI-derived inputs the
  resolver consumes before chain queries — network, wallet bech32,
  metadata path, scope id, optional validity-hours. Mirrors
  `StakeRewardInitResolverInput` minus the registry-artifact field
  (reorganize reads metadata.json, not a per-action registry
  artifact).
- **`ReorganizeResolverEnv m`** (in
  `Amaru.Treasury.Tx.ReorganizeWizard`): record-of-functions
  abstracting chain effects: wallet UTxO query (flat),
  treasury-address UTxO query (flat), upper-bound slot query,
  metadata-file read. Tests inject mocks; the live runner wires
  to `Cardano.Node.Client.Provider`.
- **`ReorganizeEnv`** (in
  `Amaru.Treasury.Tx.ReorganizeWizard`): resolved environment the
  pure translator consumes — network, upper-bound slot, parsed
  `TreasuryMetadata`, `ScopeMetadata` for the named scope, the
  selected `WalletSelection`, and the non-empty selected treasury
  UTxOs.
- **`ReorganizeError`** (extended; already shipped in #186 with
  four variants): grows with the runner-body variants per FR-001b.
  `ReorganizeTodoSliceC` is removed.
- **`ReorganizeWizardAnswers`** (already shipped in #186): the
  operator-typed answers record the runner consumes. No shape
  changes — Slice-1 already shipped every field the runner needs.

## Deliverables

| Artifact | Purpose | Surfaces touched | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` | resolver + translator + extended `ReorganizeError` | `library` stanza | yes — extend |
| `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` | replace stub with live runner; extend `exitCodeFor` | `library` stanza | yes — extend |
| `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` | runner-level tests (User Story 1–5) | `test-suite unit-tests` | yes — new |
| `amaru-treasury-tx.cabal` | expose the new spec module | `test-suite unit-tests` | yes — extend |

This slice does **not** ship:

- DevNet smoke / live-chain proof (#87)
- README / `docs/...` updates, asciinema cast
  `docs/assets/asciinema/reorganize.cast` (#188)
- Changes to the library-core reorganize build path
  (already shipped in #185 — `Tx/Reorganize.hs`,
  `Build/Reorganize.hs`)
- Changes to `lib/Amaru/Treasury/IntentJSON.hs` (the SReorganize
  arm + ReorganizeInputs codec already exist on `main`)
- Changes to `lib/Amaru/Treasury/Metadata.hs` (already exists)
- Changes to `docs/assets/intent-schema.json` (fixed by #185;
  this slice consumes the existing schema)
- Changes to the parser surface in `Cli/ReorganizeWizard.hs`
  (already shipped in #186 — minor flag additions, if any,
  surface via Q-001-A)

**Deliverables-surfaces check** (per resolve-ticket): the canonical
peer surfaces for the `amaru-treasury-tx` executable are
`.github/workflows/release.yml`, `.github/workflows/darwin-release.yml`,
`.github/workflows/darwin-dev-homebrew.yml`, `flake.nix`,
`nix/apps.nix`, `nix/checks.nix`, `README.md` install/quickstart, and
`CHANGELOG.md`. #187 modifies the executable's **behavior** of an
existing subcommand (`reorganize-wizard`); it does **not** add a new
exe, a new subcommand, a new packaging asset, or a new doc page. All
release-pipeline surfaces are already wired for `amaru-treasury-tx`;
no new wiring is needed. The asciinema cast lives in #188 (against
this slice's runner, recorded after merge). The CHANGELOG entry for
the runner is a `chore: drop gate.sh (ready for review)` follow-up
item the orchestrator updates at finalization.

## Success Criteria

### Measurable Outcomes

- **SC-001**: With a valid DevNet fixture + metadata,
  `amaru-treasury-tx reorganize-wizard …` exits 0 and the file at
  `--out` decodes as `SomeTreasuryIntent SReorganize <ti>` whose
  `ReorganizeInputs` payload matches the in-memory construction by
  `Eq`.
- **SC-002**: With `--metadata <absent>`, the wizard exits 2 and
  stderr names `ReorganizeMetadataReadError`. No node socket is
  opened.
- **SC-003**: With a chain fixture whose treasury-address query
  returns 0 or 1 UTxOs, the wizard exits 2 and stderr names
  `ReorganizeInsufficientTreasuryUtxos`. No `--out` file is written.
- **SC-004**: With `--network preprod` (or `mainnet`, or
  `preview`), the wizard exits 2 and stderr names
  `ReorganizeNonDevnetNetwork "<name>"`. No chain query is
  attempted.
- **SC-005**: With a chain fixture returning ≥2 treasury UTxOs and
  a healthy wallet, the JSON round-trip
  `decode . encode === id` (modulo documented normalization) holds
  for the runner's output bytes.
- **SC-006**:
  `grep -nE 'ReorganizeTodoSliceC' lib/Amaru/Treasury/{Cli,Tx}/ReorganizeWizard.hs`
  returns zero hits at HEAD (the TODO marker is gone). The same
  grep over `test/unit/` may still hit one spec assertion line
  that proves the marker is no longer reachable; the plan picks
  whether to keep that regression assertion.
- **SC-007**: `nix build .#checks.unit` and `./gate.sh` are green
  at HEAD when the PR is marked ready.
- **SC-008**: Every commit on `187-reorganize-wizard-runner`
  carries a Conventional Commits subject and a
  `Tasks: T###[, T###]` trailer (enforced by `./gate.sh`).

## Command-Recovery Posture

This slice promotes the operator-facing command from "parses + TODO"
to "parses + produces an intent file":

```bash
amaru-treasury-tx reorganize-wizard \
  --network devnet \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --metadata journal/2026/metadata.json \
  --wallet-addr <bech32> \
  --funding-seed-txin <txid64hex>#<word16> \
  --scope <name> \
  --out reorganize-intent.json \
  [--validity-hours <hours>] \
  [--description …] [--justification …] \
  [--destination-label …] [--event …] [--label …] \
  [--force]

amaru-treasury-tx tx-build --intent reorganize-intent.json \
  --out tx.unsigned.cbor
```

After #187 merges, an operator runs the two commands above against a
DevNet and observes an unsigned Conway tx. The first command is the
P1 user story this slice ships; the second already works (wired by
#185's dispatcher arm). The live DevNet smoke that proves this in CI
is owned by #87; the operator-facing doc page + asciinema cast are
owned by #188.

## Clarifications

### Q-001-spec-ready (open — pending epic owner verdict)

Five design choices opened at spec time. Each has a strong default
the plan can adopt if the epic owner approves the spec as-is.

- **Q-001-A: Registry-source-of-truth flag.** Issue #187's AC text
  says "Runner reads `--registry` artifact (treasury reference-script
  TxIn, hash, treasury address, scope owner)". Every existing
  wizard and the parser shipped in #186 uses `--metadata`
  (`journal/2026/metadata.json`) — which carries exactly the four
  fields the AC enumerates, plus the scope-keyed indexing reorganize
  needs. The strong default is to interpret the AC's "registry
  artifact" as the existing `--metadata` flag (already shipped in
  #186), not to add a separate `--registry` flag.
  - **Recommended verdict A1**: read everything the runner needs
    from the existing `--metadata` flag via
    `Amaru.Treasury.Metadata.readMetadataFile`. No new flag.
  - Alternative A2: add a separate `--registry` flag pointing at a
    distinct artifact (e.g. a `registry-init-wizard` output). No
    sibling precedent; would force a flag-addition commit in this
    slice (against the FR-012 "no parser-surface changes" boundary)
    and would diverge from #186's verdict α (which standardized on
    `--metadata`). Not recommended.

- **Q-001-B: Where does `permissionsRewardAccount` come from?**
  `ReorganizeInputs.permissionsRewardAccount` is required as a
  bech32 reward account. The metadata file carries
  `permissions_script.hash` (the credential) and the network magic
  is available from `GlobalOpts`. Two derivations:
  - **Recommended verdict B1**: derive the reward account inside
    `reorganizeToIntent` from `smPermissions.srHash` + the resolved
    network magic, using the existing
    `parseRewardAccountBech32`/render helpers from
    `Amaru.Treasury.IntentJSON` (or a sibling helper in
    `Amaru.Treasury.Registry.Derive`). Sibling-mirror: the
    library-core build path (#185) already expects an
    `AccountAddress` typed value, so the codec round-trips. The
    plan pins the exact helper.
  - Alternative B2: thread the permissions reward account through
    the metadata file as a separate top-level field. Would require
    a schema change to `journal/2026/metadata.json` — out of scope
    for this PR. Not recommended.

- **Q-001-C: Wallet UTxO for fuel — operator-typed or
  resolver-selected?** Sibling stake-reward-init bakes the
  operator-typed `--funding-seed-txin` verbatim into the wallet
  block, ignoring the resolver's `selectWallet` result for that
  field. The same posture matches reorganize's "operator-typed
  inter-tx values" invariant from #189.
  - **Recommended verdict C1**: bake `--funding-seed-txin` into
    `ReorganizeInputs.walletUtxo` verbatim; the wallet-addr chain
    query result is informational (its shortfall yields
    `ReorganizeWalletShortfall`, but the selected UTxO ref is
    discarded). Sibling-mirror, matches FR-006.
  - Alternative C2: use the resolver-selected wallet UTxO as the
    fuel ref and treat `--funding-seed-txin` as a verification
    cross-check (fail if they disagree). More complex; goes against
    the "operator-typed inter-tx values" invariant. Not
    recommended.

- **Q-001-D: Ordering of selected treasury UTxOs.** The
  `ReorganizeInputs.treasuryUtxos` field is a `NonEmpty TxIn`; the
  library-core build path (#185) iterates them in list order via
  `forM_`. Cardano UTxO sets are not ordered; the chain-query
  result for the treasury address is a set rendered as a list in
  whatever order the underlying provider yields. Two stances:
  - **Recommended verdict D1**: sort the selected UTxOs by
    `(TxId, TxIx)` ascending before construction. Deterministic
    output bytes, deterministic CBOR, fixture-stable. The
    library-core program does not care about order (the ledger
    canonicalises inputs).
  - Alternative D2: pass the provider's order through unchanged.
    Saves a sort; non-deterministic across providers. Not
    recommended for a fixture-driven test suite.

- **Q-001-E: "Compress until full" iteration — does this slice
  ship the per-call cap?** Upstream `select_treasury_utxos.sh`
  iterates by appending UTxOs to a candidate set until the
  resulting transaction exceeds the protocol max tx size. This is
  an iterative chain-context simulation; without the live
  chain-context the wizard cannot bound the input set safely.
  - **Recommended verdict E1**: take **all** UTxOs the
    treasury-address chain query returns (the "merge everything
    visible" semantic). The ledger guarantees the resulting tx is
    well-formed as long as the input set fits the body-size
    bound; the library-core build path (#185) already errors out
    if the size is exceeded, and that error is surfaced to the
    operator via the dispatcher in #185. Strong default for
    Slice C — the iterative cap is a follow-up enhancement
    (track under a new ticket if the operator hits the body-size
    bound in practice).
  - Alternative E2: ship a `--max-treasury-utxos <n>` flag that
    caps the selection at a fixed count. New flag → parser-surface
    change → outside FR-012. Defer.
  - Alternative E3: ship an in-runner simulation that adds UTxOs
    until the body-size estimate exceeds the protocol max.
    Requires a second `Cardano.Tx.Build` invocation per iteration
    or a body-size estimator; non-trivial. Defer to a follow-up
    ticket; the operator workflow is "if the body-size errors,
    re-run with fewer UTxOs in chain" — but reorganize doesn't
    expose a UTxO-cap flag yet, so this is a future-work caveat.

If the epic owner accepts the spec with the recommended verdicts
A1 + B1 + C1 + D1 + E1, the plan adopts them as the baseline; if
the epic owner overrides any, the plan loops back and amends the
spec section before tasks are produced.

## Non-Goals

- DevNet smoke that drives the shipped CLI against a live chain
  — #87.
- README / `docs/...` updates, asciinema cast — #188.
- Multi-scope reorganize (one `--scope` per invocation; the runner
  rejects "multi-scope" as a parser-surface concept that does not
  exist).
- Cross-step tx-body simulation — operator-typed funding seed
  TxIn is unsafe by design, matching the #156 / #158 / #159
  posture. The runner does not pre-flight the wallet's fuel
  sufficiency, nor does it cap the treasury-UTxO selection at a
  body-size bound (Q-001-E).
- Resumable client state — parked under #163. If the operator
  Ctrl-C's mid-run, they re-run.
- Changes to `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`, or
  `lib/Amaru/Treasury/Build.hs` — already shipped in #185.
- New library modules. The runner-body shape extends the existing
  two-module pair (`Cli/ReorganizeWizard.hs` +
  `Tx/ReorganizeWizard.hs`) shipped in #186.
- Touching `docs/assets/intent-schema.json` (already shipped in
  #185).

## Parent Carry-Forward Invariants

From epic #189, every child carries these invariants; #187
inherits them with these specific instantiations:

- **Reorganize tx is the simplest of the three operational
  actions**: the runner produces ONE intent JSON per invocation
  (one-shot wizard, no sub-actions, no multi-arm dispatch).
- **Construction lives in production library code, never in
  smoke specs.** The runner emits a `SomeTreasuryIntent` JSON; the
  dispatcher in `Amaru.Treasury.Build` consumes the JSON and calls
  `Build.Reorganize.runReorganizeBuild` (already shipped in #185).
  The wizard runner is a chain-context resolver + JSON encoder; it
  does NOT call any `Amaru.Treasury.Devnet.*` or `Build.*`
  construction core. The runner-spec module will carry a grep-based
  test enforcing this boundary (mirroring the sibling NFR-006 in
  `stake-reward-init`).
- **Shipped CLI surface produces unsigned txs only.** The runner
  produces JSON; the dispatcher produces unsigned Conway CBOR. The
  CLI never signs.
- **Network safety is fail-closed.** Enforced by #186's existing
  guard (re-affirmed in FR-007).
- **Operator-typed inter-tx values.** The funding-seed TxIn is
  operator-typed; everything else (treasury UTxOs, validity
  bound, treasury references, signer key hash) is
  resolver-derived from metadata + chain. Q-001-C pins the
  fuel-UTxO source.
- **Phase-1 validation includes execution units.** Not exercised
  in this slice (no tx is built); #87's live smoke is where
  exec-units coverage lands.

## Assumptions

- `Amaru.Treasury.Metadata.readMetadataFile` already accepts the
  `journal/2026/metadata.json` format unchanged. Verified
  empirically by `Amaru.Treasury.Report.*` and the existing
  devnet helpers.
- The local-node backend
  (`Amaru.Treasury.Backend.N2C.withLocalNodeBackend`) already
  exposes a flat wallet-address UTxO query and an upper-bound-slot
  query through `Cardano.Node.Client.Provider`. Verified
  empirically by the sibling stake-reward-init runner.
- `Cardano.Node.Client.Provider` exposes a flat UTxO query by
  address that returns `[(Text, Integer, Bool)]` rows or the
  equivalent. Verified empirically by
  `Amaru.Treasury.Cli.Common.queryFlat`.
- `Amaru.Treasury.Tx.SwapWizard.selectWallet` is already in the
  library closure; the sibling stake-reward-init resolver reuses
  it for wallet selection.
- The shared `Amaru.Treasury.Cli.Common.scopeReader` (or its
  equivalent) is already in scope at the parser. Verified by
  #186's parser code.
- `optparse-applicative`'s exit-code convention `(0 = ok, 1 =
  parse error, 2 = pre-flight error, 3 = runner-body error)`
  matches the sibling wizards. The runner-body variants land at
  exit 3; the pre-flight + configuration variants land at exit 2.
- `nix build .#checks.unit` is the canonical unit-test runner
  for this PR (the new spec module lives under
  `test-suite unit-tests` per the existing cabal file).
- The library codec
  (`Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent` ∘
  `decodeTreasuryIntent`) already round-trips a hand-constructed
  `SomeTreasuryIntent SReorganize <…>` value at HEAD. Verified
  by the existing IntentJSON spec module (which #185 shipped).
