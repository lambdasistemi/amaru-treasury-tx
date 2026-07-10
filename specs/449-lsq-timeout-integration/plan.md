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

## Slice 2: Stable Merge Pin

After upstream PR #184 is merged and green, replace the provisional
head with the resulting main-branch commit, independently prefetch its
SRI hash, convert it to nix32, regenerate the dependency graph, and run
the full gate again.

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

The PR remains draft until `cardano-node-clients#184` is merged. No
operator or transaction action is required while waiting for that
repository-level review decision.
