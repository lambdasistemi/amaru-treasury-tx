#!/usr/bin/env bash
# Mechanical gate for PR #242 (in-process indexer embed inside
# amaru-treasury-tx-api). Every reviewed slice must pass this before
# the orchestrator accepts the commit, and the finalization audit
# re-runs it at HEAD.
#
# Live-boundary devnet smoke is opt-in, NOT auto-gated. Run it via
#   nix develop -c just devnet-api-smoke
# with E2E_GENESIS_DIR + DEVNET_SMOKE_METADATA set. The byte-level
# N2C socket recorder that would prove "zero GetUTxOByAddress on
# the wire" is a deferred follow-up; the FR-004 invariant is
# currently proved at the Provider boundary by the unit suite
# (test/unit/Amaru/Treasury/Api/HandlersIndexerSpec.hs trappedProvider).
# See gate-script skill ("Extended by the orchestrator").
set -euo pipefail

git diff --check
nix develop --quiet -c cabal build all -O0
nix develop --quiet -c just unit
nix develop --quiet -c just golden
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
