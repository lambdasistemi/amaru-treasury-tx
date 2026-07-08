#!/usr/bin/env bash
set -euo pipefail

git diff --check

nix develop --quiet -c cabal build \
  lib:amaru-treasury-tx \
  exe:amaru-treasury-tx-api \
  -O0

nix develop --quiet -c cabal test unit-tests -O0 \
  --test-show-details=direct

nix develop --quiet -c bash -c \
  "find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +"

nix develop --quiet -c bash -c \
  "find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +"
