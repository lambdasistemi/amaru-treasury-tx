# Feature Specification: opt-env-conf treasury profile configuration

**Feature Branch**: `286-opt-env-conf`
**Created**: 2026-05-25
**Status**: Draft
**Issue**: #286: https://github.com/lambdasistemi/amaru-treasury-tx/issues/286
**Parent Epic**: #241: https://github.com/lambdasistemi/amaru-treasury-tx/issues/241
**Draft PR**: #287: https://github.com/lambdasistemi/amaru-treasury-tx/pull/287

## User Scenarios & Testing

This slice establishes the configuration layer that later multi-tenant
indexer and onboarding slices will use. It does not change transaction
building, chain queries, intent JSON, signing, or submission semantics.

### User Story 1 - Treasury operator selects a profile from config (Priority: P1)

As a treasury operator, I run:

```sh
amaru-treasury-tx --config treasury.yaml --profile acme treasury-inspect
```

and the command uses the `acme` profile's network, node socket, metadata
path, default scope, and swap-order address. If I pass an explicit CLI flag
for any of those settings, the CLI flag wins.

**Independent Test**: Parser/config tests load a fixture `treasury.yaml`,
select `acme`, and assert the resolved runtime config used by
`treasury-inspect`. A second test passes overriding CLI flags and asserts
the CLI values win.

### User Story 2 - Existing operator scripts keep working (Priority: P1)

As an existing operator, I can continue to run commands that pass
`--network`, `--network-magic`, and `--node-socket`, or that rely on
`CARDANO_NODE_SOCKET_PATH`, without adding a config file.

**Independent Test**: Existing flag-only parser examples still resolve to
the same `GlobalOpts` and command-specific records as before.

### User Story 3 - API operator starts the dashboard from the same config machinery (Priority: P2)

As an API operator, I run:

```sh
amaru-treasury-tx-api --config treasury.yaml --profile acme
```

and the server reads socket, metadata, manifest, build identity, and static
asset paths through the same source-merging rules as the CLI. Existing
explicit API flags remain accepted and override config/env values.

**Independent Test**: API parser/config tests cover config-only success,
env-only success, CLI-overrides-config, and old flag-only invocation.

## Requirements

- **FR-001**: Add `opt-env-conf` as the configuration dependency for the
  shipped library/executables that parse operator-facing settings.
- **FR-002**: Introduce a typed `TreasuryProfileConfig` with at least:
  `profileName`, `network`, `nodeSocket`, `metadataPath`, optional
  `tenantId`, optional `defaultScope`, optional `walletAddress`, and
  optional `swapOrderAddress`.
- **FR-003**: Split configuration complexity across focused modules. Do not
  put all types, file loading, source parsing, precedence resolution, CLI
  adaptation, and API adaptation in one large module.
- **FR-004**: Introduce a runtime config resolver that merges sources with
  this precedence: explicit CLI flag > environment variable > selected
  profile in config file > existing default.
- **FR-005**: `amaru-treasury-tx` MUST accept `--config PATH` and
  `--profile NAME`.
- **FR-006**: The CLI config path and profile MUST also be accepted through
  documented `AMARU_TREASURY_*` environment variables.
- **FR-007**: Existing global flags MUST keep their names and behavior:
  `--network`, `--network-magic`, and `--node-socket` remain accepted.
- **FR-008**: `CARDANO_NODE_SOCKET_PATH` MUST remain accepted as a
  compatibility alias in the environment tier. If both it and
  `AMARU_TREASURY_NODE_SOCKET` are set, the namespaced variable wins.
- **FR-009**: At least `treasury-inspect` MUST consume `metadataPath`,
  `defaultScope`, and `swapOrderAddress` from the selected profile when the
  corresponding command flags are omitted.
- **FR-010**: `treasury-inspect` MUST still allow `--metadata`, `--scope`,
  and `--swap-order-address` to override the selected profile.
- **FR-011**: `amaru-treasury-tx-api` MUST consume the same config machinery
  for `--socket`, `--metadata`, `--manifest`, `--build-identity`, and
  `--static`, while preserving its current explicit flags.
- **FR-012**: Parser/config tests MUST cover config-only success, env-only
  success, CLI-overrides-config, missing required field diagnostics,
  unknown profile diagnostics, malformed config diagnostics, and
  backward-compatible flag-only invocation.
- **FR-013**: Operator docs MUST include a minimal `treasury.yaml` example
  and state that `tenantId` is reserved for later multi-tenant indexer
  slices.
- **FR-014**: Transaction intent JSON schemas, transaction builders, and
  on-chain assumptions MUST remain unchanged.

## Config Format

Runtime config for this slice is YAML, because `opt-env-conf` provides YAML
configuration loaders directly. JSON config is not added in this slice.

Minimal example:

```yaml
profiles:
  acme:
    profileName: acme
    tenantId: acme
    network: mainnet
    nodeSocket: /run/cardano/node.socket
    metadataPath: metadata-mainnet.json
    defaultScope: core_development
    walletAddress: addr1...
    swapOrderAddress: addr1...

api:
  manifest: recent-txs.json
  buildIdentity: build-identity.json
  static: frontend/dist
```

Documented environment names:

- `AMARU_TREASURY_CONFIG`
- `AMARU_TREASURY_PROFILE`
- `AMARU_TREASURY_NETWORK`
- `AMARU_TREASURY_NETWORK_MAGIC`
- `AMARU_TREASURY_NODE_SOCKET`
- `CARDANO_NODE_SOCKET_PATH` (compatibility alias)
- `AMARU_TREASURY_METADATA`
- `AMARU_TREASURY_DEFAULT_SCOPE`
- `AMARU_TREASURY_TENANT_ID`
- `AMARU_TREASURY_WALLET_ADDRESS`
- `AMARU_TREASURY_SWAP_ORDER_ADDRESS`
- `AMARU_TREASURY_API_MANIFEST`
- `AMARU_TREASURY_API_BUILD_IDENTITY`
- `AMARU_TREASURY_API_STATIC`

## Edge Cases

- `--profile` names a profile missing from the config file: fail before
  running the command and name the unknown profile.
- `--profile` is supplied without `--config` and no config path exists in
  the environment: fail with a profile/config diagnostic.
- The config file is unreadable or malformed YAML: fail before running the
  command and report the file path.
- A selected profile omits a field required by the command being run:
  report the missing field and the selected profile.
- Both `--network` and `--network-magic` are supplied with contradictory
  values: keep existing behavior if already defined; otherwise reject the
  contradiction in config resolution.
- A profile uses an unknown network name: reuse the existing
  `mainnet|preprod|preview|devnet` diagnostic shape where possible.
- `CARDANO_NODE_SOCKET_PATH` is set but `AMARU_TREASURY_NODE_SOCKET` is not:
  resolve the socket from the legacy env var.
- Config supplies a `defaultScope` that is not present in the loaded
  metadata: `treasury-inspect` fails with its existing scope validation
  diagnostic.

## Success Criteria

- **SC-001**: `amaru-treasury-tx --config treasury.yaml --profile acme
  treasury-inspect` resolves the selected profile's network, socket,
  metadata path, default scope, and swap-order address.
- **SC-002**: A flag-only invocation using today's `--network`,
  `--network-magic`, `--node-socket`, and command flags resolves
  identically to current behavior.
- **SC-003**: Parser/config tests prove precedence for CLI over env over
  config over defaults.
- **SC-004**: `amaru-treasury-tx-api --config treasury.yaml --profile acme`
  resolves socket, metadata, manifest, build identity, and static path from
  config when CLI flags are omitted.
- **SC-005**: Docs contain a copy-pasteable `treasury.yaml` example and a
  short note that `tenantId` is reserved for later multi-tenant indexer
  work.
- **SC-006**: The resulting config implementation is split across focused
  modules with a small facade, not a single large module.
- **SC-007**: `./gate.sh` is green, subject only to repository dependency
  availability outside this PR's diff.

## Out of Scope

- Implementing the multi-tenant indexer.
- Adding HTTP tenant routing.
- Changing transaction intent JSON schemas.
- Changing on-chain contract assumptions.
- Removing compatibility for existing scripts.
- Migrating internal dev-only probes unless it falls out mechanically and
  safely.
- Adding JSON config support. The migration note can mention the existing
  `operator.json` convention, but this runtime config uses YAML first.
