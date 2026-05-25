# Implementation Plan: opt-env-conf treasury profile configuration

**Branch**: `286-opt-env-conf` | **Date**: 2026-05-25 | **Spec**: [spec.md](./spec.md)
**Issue**: #286: https://github.com/lambdasistemi/amaru-treasury-tx/issues/286
**Parent Epic**: #241: https://github.com/lambdasistemi/amaru-treasury-tx/issues/241
**Draft PR**: #287: https://github.com/lambdasistemi/amaru-treasury-tx/pull/287

## Summary

Replace the shipped operator-facing configuration surface for
`amaru-treasury-tx` and `amaru-treasury-tx-api` with an
`opt-env-conf`-backed runtime config layer. The user-visible proof is a
profile-selectable `treasury-inspect` flow and the API server reading its
startup paths through the same source-merging rules. Existing flag-only
commands remain valid.

This is Slice 0 of the multi-tenant epic: it makes the system configurable
for more than one treasury profile without changing any transaction or
contract semantics.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository flake.
**Primary Dependencies**: `opt-env-conf` for arg/env/config settings,
existing Cardano and servant dependencies unchanged.
**Reference Docs**: Current `opt-env-conf` docs describe settings that can
read command-line args, environment variables, and config values, and expose
YAML config loaders such as `withYamlConfig` and `withLocalYamlConfig`:
https://www.stackage.org/package/opt-env-conf
**Storage**: Optional YAML file supplied by `--config` or
`AMARU_TREASURY_CONFIG`; no database and no generated state.
**Testing**: Hspec unit tests for pure config resolution and entry-point
parser behavior. Keep existing golden/transaction tests untouched except for
compatibility fallout.
**Constraint**: Preserve existing explicit flags and
`CARDANO_NODE_SOCKET_PATH`. No intent JSON or transaction byte drift.

## Current Code Inventory

- `lib/Amaru/Treasury/Cli.hs` owns the top-level `Options.Applicative`
  command tree for `amaru-treasury-tx`.
- `lib/Amaru/Treasury/Cli/Common.hs` owns `GlobalOpts`, network parsing,
  and `CARDANO_NODE_SOCKET_PATH` socket fallback.
- `lib/Amaru/Treasury/Cli/TreasuryInspect.hs` owns the first command that
  will consume profile defaults: `--metadata`, `--scope`,
  `--swap-order-address`.
- `app/amaru-treasury-tx-api/Main.hs` owns a separate optparse parser for
  host, port, socket, metadata, manifest, build identity, and static files.
- `test/unit/Amaru/Treasury/Cli/*Spec.hs` currently drives many parsers
  through `Options.Applicative.execParserPure`.
- `docs/quickstart.md`, `docs/inspect.md`, and API deployment notes are the
  first operator docs to update.

## Module Boundaries

Do not implement this as one large `Config.hs`. Use a facade plus focused
modules so complexity stays reviewable:

```text
lib/Amaru/Treasury/Config.hs              # small facade/re-export module
lib/Amaru/Treasury/Config/Types.hs        # TreasuryProfileConfig, ApiConfig, source tags
lib/Amaru/Treasury/Config/File.hs         # YAML file shape and loading
lib/Amaru/Treasury/Config/OptEnv.hs       # opt-env-conf parsers/settings
lib/Amaru/Treasury/Config/Resolve.hs      # precedence merge and diagnostics
lib/Amaru/Treasury/Cli/Config.hs          # CLI adapter to existing GlobalOpts/Cmd shapes
lib/Amaru/Treasury/Api/Config.hs          # API adapter to server startup options
```

Expected ownership:

- `Types` has no parser or IO dependency.
- `File` handles YAML file decoding only.
- `OptEnv` names CLI flags and environment variables.
- `Resolve` is pure where possible and owns precedence diagnostics.
- `Cli.Config` adapts resolved values into existing CLI runtime records.
- `Api.Config` adapts resolved values into API startup records.
- The facade `Amaru.Treasury.Config` re-exports only the stable public
  surface used by tests and executables.

## Architecture

Resolve each field independently:

```text
CLI flag > AMARU_TREASURY_* env > selected profile YAML > existing default
```

Socket env compatibility:

```text
--node-socket / --socket
  > AMARU_TREASURY_NODE_SOCKET
  > CARDANO_NODE_SOCKET_PATH
  > profile.nodeSocket
```

If no source provides a required field for the command being run, fail with
the missing field and profile name before command IO starts.

Use YAML for this runtime config. `opt-env-conf` exposes YAML config loading
directly, so YAML gives the least custom parsing code for this first
tenant/profile slice. Do not add a parallel JSON config parser in this
ticket.

The implementation should not hand-roll an ad hoc pre-parser. The shipped
entry point should call an `opt-env-conf` parser/resolver for its
operator-facing settings.

Keep this slice narrow:

- Migrate the CLI runtime config surface and the `treasury-inspect`
  defaults first.
- Keep command option record shapes stable unless the command consumes
  profile defaults in this ticket.
- Migrate the API parser onto the same config/resolver module.
- Do not migrate dev-only probes.

If retaining some `Options.Applicative` parser modules is required to keep
the PR bisect-safe, document that as legacy command-parser scope in
`WIP.md` and ensure the replaced shipped entry-point config surface is
owned by `opt-env-conf`.

## Project Structure

```text
amaru-treasury-tx/
+-- lib/Amaru/Treasury/
|   +-- Config.hs
|   +-- Config/
|   |   +-- File.hs
|   |   +-- OptEnv.hs
|   |   +-- Resolve.hs
|   |   +-- Types.hs
|   +-- Api/
|   |   +-- Config.hs
|   +-- Cli/
|       +-- Config.hs
|       +-- Common.hs
|       +-- Cli.hs
|       +-- TreasuryInspect.hs
+-- app/amaru-treasury-tx-api/
|   +-- Main.hs
+-- test/unit/Amaru/Treasury/
|   +-- Config/
|   |   +-- FileSpec.hs
|   |   +-- OptEnvSpec.hs
|   |   +-- ResolveSpec.hs
|   +-- Cli/ParserSpec.hs
|   +-- Api/ConfigSpec.hs
+-- specs/286-opt-env-conf/
    +-- spec.md
    +-- plan.md
    +-- tasks.md
```

The exact test module names can shift if the current suite layout makes a
more local name cleaner, but the PR must include focused parser/config
coverage at the module boundaries above.

## Slice Plan

### Slice 1 - Shared config model and precedence resolver

Add `opt-env-conf` to the relevant Cabal stanzas. Add the config data model,
YAML file loader, opt-env-conf settings parser, and pure resolver with tests
for profile lookup, precedence, socket env aliasing, unknown profile,
malformed/missing fields, and network conversion. This slice does not
change command behavior.

### Slice 2 - CLI entry point and `treasury-inspect`

Wire `amaru-treasury-tx` to accept `--config`, `--profile`, and
`AMARU_TREASURY_*` through `Cli.Config`. Keep `--network`,
`--network-magic`, `--node-socket`, and `CARDANO_NODE_SOCKET_PATH`
compatible. Apply profile defaults to `treasury-inspect` for metadata,
scope, and swap-order address. Preserve flag-only invocation tests.

### Slice 3 - API entry point

Move `amaru-treasury-tx-api` startup config to `Api.Config`. Preserve
`--host`, `--port`, `--socket`, `--metadata`, `--manifest`,
`--build-identity`, and `--static`, with explicit flags overriding env and
YAML. Add tests for config-only, env-only, CLI-overrides-config, and
flag-only startup config.

### Slice 4 - Operator docs and final gate

Document `treasury.yaml`, env names, precedence, tenantId reservation, and
the compatibility story. Run the gate, update the PR body, and leave
`gate.sh` in place while the PR is draft.

## Risks

- `opt-env-conf` may not expose a pure parser runner equivalent to
  `execParserPure`; tests may need to drive lower-level parser functions or
  process-level invocations. Confirm in Slice 1 before broad rewrites.
- The current top-level parser and tests are optparse-shaped. Keep commits
  small so compatibility failures are isolated.
- Config precedence can become unclear if command-specific flags retain
  defaults before the merge layer sees missing values. Represent omitted CLI
  values as `Maybe` until after config resolution.
- Network handling currently defaults to mainnet. Preserve that default only
  when neither CLI, env, nor config supplied network information.
- API config has fields outside `TreasuryProfileConfig`. Keep API-specific
  paths in `ApiConfig` rather than overloading treasury profile fields.

## Verification

Run at minimum:

```sh
./gate.sh
nix develop --quiet -c just unit "Config"
nix develop --quiet -c just unit "Cli"
```

For the API slice, also run the focused API parser/config tests. The current
bootstrap gate is known to be blocked by an upstream dependency fetch for
`cuddle-1.1.1.0`; record that exact failure when it occurs and re-run once
the dependency is available.

## Commit Shape

- `chore: add gate.sh for issue 286` - already pushed as draft scaffold.
- `docs: add issue 286 spec plan tasks` - this planning commit.
- `feat(config): add treasury profile resolver`
- `feat(cli): read treasury-inspect defaults from profile config`
- `feat(api): read startup paths from treasury config`
- `docs: document treasury profile config`

Behavior-changing commits should carry `Tasks:` trailers matching
[tasks.md](./tasks.md). Planning/docs-only commits may omit task trailers
unless they close a listed docs task.
