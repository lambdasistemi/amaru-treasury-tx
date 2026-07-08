#!/usr/bin/env bash
set -euo pipefail

git diff --check

# Keep this scoped away from `cabal build all`: the full build is
# known to be blocked by the pre-existing cuddle dependency pin (#458).
nix develop --quiet -c cabal build lib:amaru-treasury-tx -O0

# Match CI lint surfaces exactly: full-tree fourmolu check and hlint.
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
