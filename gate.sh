#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c bash -lc '
  diff -u amaru-treasury-tx.cabal \
    <(cabal-fmt amaru-treasury-tx.cabal)
  find . -type f -name "*.hs" \
    -not -path "*/dist-newstyle/*" \
    -exec fourmolu -m check {} +
  find . -type f -name "*.hs" \
    -not -path "*/dist-newstyle/*" \
    -exec hlint {} +
'
nix develop --quiet -c cabal build lib:amaru-treasury-tx exe:amaru-treasury-tx-api -O0
nix develop --quiet -c cabal test unit-tests -O0
