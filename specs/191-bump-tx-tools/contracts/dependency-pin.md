# Contract: cardano-tx-tools dependency pin

## Owner

`cabal.project` is the canonical dependency contract for this ticket.

## Required `source-repository-package`

```cabal
source-repository-package
  type: git
  location: https://github.com/lambdasistemi/cardano-tx-tools
  tag: 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13
  --sha256: <nix32 hash for 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13>
```

## Rules

- `tag:` must be commit
  `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`.
- `tag:` must not be annotated tag object
  `d53943d842b740b313b6b67c7784f4308e5847f0`.
- The fixed-output hash must be regenerated for the commit above.
- A stale or wrong hash must fail the Nix fetch before the slice is
  accepted.
- No other dependency pin changes in #191.

## Verification

```bash
gh api \
  repos/lambdasistemi/cardano-tx-tools/git/tags/d53943d842b740b313b6b67c7784f4308e5847f0 \
  --jq '.object.sha'

gh api \
  repos/lambdasistemi/cardano-tx-tools/compare/6a7a7d424594e8d891dd2b7df5c4e9a7884e6779...9e77e90728729bdd22e3bfbe0cf7515b33d5ea13 \
  --jq '{status,ahead_by,behind_by}'

nix flake check
```
