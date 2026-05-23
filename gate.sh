#!/usr/bin/env bash
# Mechanical gate for PR #242 (in-process indexer embed inside
# amaru-treasury-tx-api). Every reviewed slice must pass this before
# the orchestrator accepts the commit, and the finalization audit
# re-runs it at HEAD.
#
# Will grow during plan/tasks to add:
#   - a focused unit pattern for the indexer runner module,
#   - a live-boundary smoke that issues an HTTP request to a running
#     api container and asserts zero GetUTxOByAddress on the node
#     socket trace.
# See gate-script skill ("Extended by the orchestrator").
set -euo pipefail

git diff --check
nix develop --quiet -c cabal build all -O0
nix develop --quiet -c just unit
nix develop --quiet -c just golden
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
