#!/usr/bin/env bash
set -euo pipefail

git diff --check

# Mirrors just ci without the known-broken cabal build all target (#458).
nix develop --quiet -c just schema-check
nix develop --quiet -c just unit
nix develop --quiet -c just golden
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
nix develop --quiet -c just smoke
nix develop --quiet -c just release-check
