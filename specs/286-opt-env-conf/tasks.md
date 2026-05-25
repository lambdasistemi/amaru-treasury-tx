# Tasks: opt-env-conf treasury profile configuration

**Input**: [spec.md](./spec.md), [plan.md](./plan.md), issue #286
**Prerequisites**: draft PR #287 exists; `gate.sh` exists.
**TDD**: tests precede behavior changes inside each implementation slice.
**Commit discipline**: one bisect-safe behavior commit per slice. Commit
trailers should use the task IDs below, for example `Tasks: T286001`.

## Slice 1 - Shared config modules and precedence resolver

- [X] T286001 Research the `opt-env-conf` test/run API enough to choose how
  unit tests will drive arg/env/YAML resolution. Record any limitation in
  `WIP.md`.
- [X] T286002 Add the `opt-env-conf` dependency to the library, CLI, API,
  and unit-test Cabal stanzas that need it. Keep `optparse-applicative`
  only where still required by legacy command parsers or tests.
- [X] T286003 Add module skeletons and Cabal exposure for
  `Amaru.Treasury.Config`, `Config.Types`, `Config.File`,
  `Config.OptEnv`, `Config.Resolve`, `Cli.Config`, and `Api.Config`.
- [X] T286004 RED: add focused tests for `Config.File` covering YAML
  profile decoding, malformed YAML, missing profile map, and optional API
  section decoding.
- [X] T286005 RED: add focused tests for `Config.Resolve` covering
  config-only success, env-only success, CLI-overrides-config, socket env
  aliasing, unknown profile, and missing required field diagnostics.
- [X] T286006 GREEN: implement `Config.Types`, `Config.File`, and
  `Config.Resolve` with pure precedence helpers where possible.
- [X] T286007 GREEN: implement `Config.OptEnv` with the shared
  `opt-env-conf` settings for config path, profile, network, socket,
  metadata, default scope, tenant id, wallet address, swap-order address,
  and API-specific paths.
- [X] T286008 Run focused config tests, run `./gate.sh` if dependency fetch
  permits, record evidence in `WIP.md`, and commit Slice 1.

## Slice 2 - CLI entry point and `treasury-inspect`

- [X] T286009 RED: extend CLI parser/config tests for
  `amaru-treasury-tx --config treasury.yaml --profile acme treasury-inspect`
  resolving profile metadata, default scope, network, socket, and
  swap-order address.
- [X] T286010 RED: add compatibility tests proving existing flag-only
  invocations still accept `--network`, `--network-magic`, `--node-socket`,
  command-specific `--metadata`, `--scope`, and `--swap-order-address`.
- [X] T286011 GREEN: implement `Amaru.Treasury.Cli.Config` as the only CLI
  adapter from the shared config modules into existing `GlobalOpts` and
  command runtime shapes.
- [X] T286012 GREEN: migrate the shipped CLI runtime config surface in
  `lib/Amaru/Treasury/Cli.hs` / `Cli/Common.hs` onto `Cli.Config` while
  preserving the existing `Cmd` and `GlobalOpts` runtime shapes where
  practical.
- [X] T286013 GREEN: update `lib/Amaru/Treasury/Cli/TreasuryInspect.hs` so
  omitted `--metadata`, `--scope`, and `--swap-order-address` are filled
  from the selected profile before command IO starts.
- [X] T286014 Run focused CLI tests, run `./gate.sh` if dependency fetch
  permits, record evidence in `WIP.md`, and commit Slice 2.

## Slice 3 - API entry point

- [ ] T286015 RED: add `Amaru.Treasury.Api.ConfigSpec` for API startup
  config-only success, env-only success, CLI-overrides-config, missing
  required field diagnostics, and old flag-only invocation.
- [ ] T286016 GREEN: implement `Amaru.Treasury.Api.Config` as the only API
  adapter from the shared config modules into the server startup option
  record.
- [ ] T286017 GREEN: migrate `app/amaru-treasury-tx-api/Main.hs` to consume
  `Api.Config` for `--socket`, `--metadata`, `--manifest`,
  `--build-identity`, and `--static`, while preserving `--host` and
  `--port` behavior.
- [ ] T286018 GREEN: document and test API-specific env variables:
  `AMARU_TREASURY_API_MANIFEST`,
  `AMARU_TREASURY_API_BUILD_IDENTITY`, and
  `AMARU_TREASURY_API_STATIC`.
- [ ] T286019 Run focused API tests, run `./gate.sh` if dependency fetch
  permits, record evidence in `WIP.md`, and commit Slice 3.

## Slice 4 - Operator docs, PR metadata, and final draft state

- [ ] T286020 Update `docs/quickstart.md` and `docs/inspect.md` with a
  minimal `treasury.yaml`, `--config` / `--profile` examples, env names,
  precedence, `CARDANO_NODE_SOCKET_PATH` compatibility, and the `tenantId`
  reserved-for-indexer note.
- [ ] T286021 Update API deployment/operator docs or inline help examples
  for `amaru-treasury-tx-api --config treasury.yaml --profile acme`.
- [ ] T286022 Update PR #287 body with completed acceptance evidence,
  remaining dependency/gate caveats if any, and links to issue #286 and
  parent epic #241.
- [ ] T286023 Run final focused tests and `./gate.sh` if dependency fetch
  permits; record the exact pass/fail evidence in `WIP.md`.
- [ ] T286024 Commit Slice 4 docs/metadata changes and push. Keep the PR in
  draft until behavior slices and gate evidence are reviewed.

## Dependencies

```text
Slice 1 blocks all behavior work.
Slice 2 depends on Slice 1.
Slice 3 depends on Slice 1 and can run after or alongside review of Slice 2.
Slice 4 depends on Slices 2 and 3 for accurate docs.
```

## Parallelization Notes

- After Slice 1 lands, CLI and API migration can be worked independently if
  ownership is split cleanly:
  - CLI owner: `lib/Amaru/Treasury/Cli/Config.hs`,
    `lib/Amaru/Treasury/Cli.hs`, `Cli/Common.hs`,
    `Cli/TreasuryInspect.hs`, CLI tests.
  - API owner: `lib/Amaru/Treasury/Api/Config.hs`,
    `app/amaru-treasury-tx-api/Main.hs`, API config tests.
- Docs should wait until the final env names and YAML shape are stable.
