# Issue #456 Plan

## Context

Epic #451 introduced typed, contravariant tracing and generic provider
instrumentation. Issue #456 is the cleanup step that removes the
temporary `stderr` markers added during the #449/#450 incident once
production evidence confirms generic provider traces cover the same
call sites.

## Owned Implementation Files

- `lib/Amaru/Treasury/ChainContext.hs`
- `lib/Amaru/Treasury/Registry/Verify.hs`

## Forbidden Scope

- `lib/Amaru/Treasury/Api/RateLimit.hs`
- Any transaction-building behavior
- Any signing, submission, or production mutation
- Epic #451 issue body or sibling ticket scope

## Slice Breakdown

### Slice 1: Remove Stopgap Tracing

Remove only the ad-hoc debug helpers and their call sites:

- Delete `dbg` and `dbgEvaluateTx` from `ChainContext`.
- Delete `dbg` from `Registry.Verify`.
- Remove imports that exist only for those helpers.
- Leave all provider calls and generic tracing construction untouched.

Proof:

- Compile the library target.
- Run full-tree `format-check` and `hlint` through `./gate.sh`.
- After the branch is deployed or otherwise available on production,
  rerun the build-only `/v1/build/disburse` request and verify generic
  provider traces remain while stopgap lines are absent.

## Gate

`./gate.sh` intentionally avoids `cabal build all` because the full
build path is currently blocked by the known pre-existing `cuddle`
dependency pin tracked in #458. It does run:

- `git diff --check`
- `nix develop --quiet -c cabal build lib:amaru-treasury-tx -O0`
- `nix develop --quiet -c just format-check`
- `nix develop --quiet -c just hlint`

The format and hlint checks match the full-tree CI lint surfaces.

## Post-Removal Live Verification

Use the same production command recorded in `spec.md`. Acceptance
requires a log tail showing:

- no `amaru-treasury: chain-context:` lines
- no `amaru-treasury: registry-verify:` lines
- retained `[Info] provider.withAcquired`,
  `[Info] provider.handle.queryUTxOByTxInH`,
  `[Info] provider.queryProtocolParams`,
  `[Info] provider.queryUTxOByTxIn`,
  `[Info] provider.queryLedgerSnapshot`, and
  `[Info] provider.evaluateTx` traces for the request path

If production is still running the old image, this check is blocked
until the PR head is deployed; do not mark the ticket complete before
the post-removal evidence exists.
