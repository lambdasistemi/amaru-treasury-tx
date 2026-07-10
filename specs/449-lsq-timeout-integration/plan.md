# Issue #449 Plan

## Context

Issue #449's 60-second API timeout prevents a stalled request from
holding the single-flight limiter forever, but it does not heal the
long-lived provider connection. The root fix is the bounded
LocalStateQuery response wait and connection-generation reconnect in
`cardano-node-clients#184`.

The existing Amaru pin predates that fix. Integration is intentionally
split because the upstream PR must be tested downstream before review,
but the final Amaru pin must name the stable merge commit rather than an
unmerged feature-branch head.

## Owned Implementation Files

- `cabal.project`
- `docs/dependencies.md`

## Forbidden Scope

- `lib/Amaru/Treasury/Api/RateLimit.hs`
- All other production and test modules
- `transactions/` and `journal/`
- Mainnet node access, transaction building, signing, or submission
- Spec, plan, task, gate, and PR metadata files owned by the
  orchestrator

## Slice 1: Provisional Downstream Integration

Pin `cardano-node-clients` to PR #184 head
`c5b9259b1050404c47c1bc410bf6569d1f63c914` using the independently
prefetched nix32 hash
`0zhx2983dhi6cjnc88vy3z2ajkg7cdk6xhsv4h1r7drh8nmb9jws`.

Regenerate `docs/dependencies.md` with the canonical dependency-graph
tool in deterministic no-staleness mode. Run `./gate.sh`. If the newer
client requires changes outside the two owned files, stop and report a
Q-file with the exact compiler or solver evidence before expanding
scope.

## Slice 1B: Corrected Provisional Head

The first provisional head was superseded while upstream live-boundary
verification exposed and fixed two further problems: the connection
monitor had moved the stateful mini-protocol action to a child thread,
and the upstream E2E executable lacked `-threaded`. Replace that head
with the corrected PR #184 head
`b2dfea882c379a3994813fd6ba2eaf374eeb510a`, using the independently
prefetched nix32 hash
`0bxj3rzq6bz2kcqllmaq4yqikf7jsrfynhd75dl93c0qpyv0g3vr`.

Regenerate `docs/dependencies.md` in deterministic no-staleness mode
and run the complete downstream gate. This remains a provisional pin:
the PR stays draft until upstream is merged and Slice 2 replaces it
with a stable main-branch commit.

## Slice 2: Stable Merge Pin

Upstream PR #184 was rebase-merged with green CI and released as
`v0.1.4.0`. Replace the provisional head with its stable release commit
`b13ce509c0c09f8340ba49d03a3d76505721103d`, using independently
prefetched SRI
`sha256-ESb9+OBW5EplrIpjM4RSse3i7AMD7AybuRcg6cYBlqY=` and nix32
`19ln073fj80pp6dhrv030gnf5vdiaa236qwamijlmr2nw3wgs9hi`. Regenerate
the dependency graph and run the full gate again.

If the merge commit has the same source tree as the provisional head,
the second slice still updates the revision and hash: the acceptance
contract is a stable main-branch dependency, not a feature-branch pin.

## Gate

`./gate.sh` runs:

- `git diff --check`
- `nix develop --quiet -c just ci`

The upstream protocol regression provides RED/GREEN evidence for the
bug itself. The Amaru gate proves that every downstream build and test
surface resolves and works with the fixed library.

## External Blocker

Resolved: `cardano-node-clients#184` is merged, main CI is green, and
the stable `v0.1.4.0` tag names the release commit above. Slice 2 may
now finalize this PR for merge and release.
