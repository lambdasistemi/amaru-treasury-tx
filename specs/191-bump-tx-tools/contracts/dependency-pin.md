# Contract: cardano-tx-tools dependency pin

## Owner

`cabal.project` is the canonical dependency contract for this ticket.

## Required `source-repository-package` pins

```cabal
source-repository-package
  type: git
  location: https://github.com/lambdasistemi/cardano-tx-tools
  tag: 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13
  --sha256: 0vkrnf05jsy3mkc6kvgi5msc8j1a356zvr6sxnxxfwmysqjq5qv4

source-repository-package
  type: git
  location: https://github.com/lambdasistemi/github-release-check
  tag: d90131112a4d6c048d1809adaffdefed92e8e841
  --sha256: 0ad6yi431w8h5i3x9x661b99frcgvd39gm4164y8cx1ihpsjixn3
```

## Rules

- `cardano-tx-tools` `tag:` must be commit
  `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`.
- `cardano-tx-tools` `tag:` must not be annotated tag object
  `d53943d842b740b313b6b67c7784f4308e5847f0`.
- The fixed-output hashes must be regenerated for the commits above.
- A stale or wrong hash must fail the Nix fetch before the slice is
  accepted.
- The `github-release-check` pin is an upstream-companion mirror, not an
  independent dependency upgrade. It must match the commit and nix32
  hash named in the pinned `cardano-tx-tools` commit's own
  `cabal.project`, because `cardano-tx-tools-0.2.0.0` requires the
  newer public `github-release-check:optparse` sublibrary.
- No dependency pin changes are allowed in #191 unless they are the
  primary `cardano-tx-tools` bump or upstream-companion mirrors required
  by that exact commit's own `cabal.project`.

## Verification

```bash
gh api \
  repos/lambdasistemi/cardano-tx-tools/git/tags/d53943d842b740b313b6b67c7784f4308e5847f0 \
  --jq '.object.sha'

gh api \
  repos/lambdasistemi/cardano-tx-tools/compare/6a7a7d424594e8d891dd2b7df5c4e9a7884e6779...9e77e90728729bdd22e3bfbe0cf7515b33d5ea13 \
  --jq '{status,ahead_by,behind_by}'

nix flake check

curl -sL \
  https://raw.githubusercontent.com/lambdasistemi/cardano-tx-tools/9e77e90728729bdd22e3bfbe0cf7515b33d5ea13/cabal.project \
  | grep -A 4 github-release-check
```
