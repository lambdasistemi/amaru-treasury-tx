# Quickstart: bump cardano-tx-tools reward-state validation

This feature has no operator command. The maintainer workflow is the
dependency and validation proof sequence below.

## 1. Verify the target commit

```bash
gh api \
  repos/lambdasistemi/cardano-tx-tools/git/tags/d53943d842b740b313b6b67c7784f4308e5847f0 \
  --jq '.object.sha'

gh api \
  repos/lambdasistemi/cardano-tx-tools/compare/6a7a7d424594e8d891dd2b7df5c4e9a7884e6779...9e77e90728729bdd22e3bfbe0cf7515b33d5ea13 \
  --jq '{status,ahead_by,behind_by}'
```

Expected target commit:

```text
9e77e90728729bdd22e3bfbe0cf7515b33d5ea13
```

Expected compare result: `status = ahead`, `ahead_by > 0`,
`behind_by = 0`.

## 2. Update `cabal.project`

Set the `cardano-tx-tools` source-repository-package to the commit SHA,
not the annotated tag object:

```cabal
source-repository-package
  type: git
  location: https://github.com/lambdasistemi/cardano-tx-tools
  tag: 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13
  --sha256: <nix32 hash for that exact commit>
```

Regenerate the nix32 hash for that exact commit before committing the
pin.

## 3. Run focused validation proofs

Run the focused unit/golden patterns chosen in `tasks.md`. The minimum
set must cover:

- withdrawal-bearing final Phase-1 validation through
  `validateFinalPhase1`
- governance-withdrawal-init materialization fixture behavior
- governance-withdrawal-init proposal skip disposition

## 4. Run gates

```bash
./gate.sh
nix flake check
```

`./gate.sh` is required for every accepted slice. `nix flake check` is
the full reproducibility proof for the dependency bump before the PR can
leave draft.

## 5. Update PR metadata

PR #192 must name:

- upstream commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`
- old commit `25d7ce349f826e9888fb8565eeb816babb06d922`
- target release `v0.2.0.0`
- regenerated hash proof
- whether each validation workaround was removed or retained with a
  residual ledger rule
