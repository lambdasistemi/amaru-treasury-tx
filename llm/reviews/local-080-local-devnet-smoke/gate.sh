#!/usr/bin/env bash
set -euo pipefail

nix develop --quiet -c just unit network

if grep -q '^test-suite devnet-tests' amaru-treasury-tx.cabal; then
  nix develop --quiet -c cabal test devnet-tests -O0 \
    --test-show-details=direct \
    --test-option=--match \
    --test-option=node
fi

if just --list | grep -q '^    devnet-smoke'; then
  nix develop --quiet -c just devnet-smoke node
fi
