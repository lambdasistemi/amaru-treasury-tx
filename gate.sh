#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c cabal build \
    lib:amaru-treasury-tx \
    exe:amaru-treasury-tx-api \
    -O0
nix develop --quiet -c just unit "Trace"
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
