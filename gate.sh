#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c cabal build lib:amaru-treasury-tx exe:amaru-treasury-tx-api -O0
nix develop --quiet -c cabal test unit-tests -O0
