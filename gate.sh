#!/usr/bin/env bash
set -euo pipefail

# PR lifecycle gate for #409 (treasury swap e2e on devnet).
# Mirrors the repo convention (cf. #400): the pre-commit hook execs this
# file while it exists, so every behaviour-changing commit must pass
# `just ci` (build + schema-check + unit + golden + format-check + hlint
# + smoke + release-check). Dropped in a `chore: drop gate.sh` commit
# before the PR leaves draft.
#
# NOTE: the live-boundary devnet smoke that IS this ticket's deliverable
# proof is intentionally NOT part of this per-commit gate (it is
# node-backed and too expensive to run on every commit, exactly like
# `just ci` excludes the devnet smokes). The driver runs it explicitly
# per slice and records the evidence in WIP.md / the PR body:
#
#   E2E_GENESIS_DIR=/code/cardano-node-clients/devnet/genesis \
#   SUNDAE_CONTRACTS_DIR=/tmp/attx-409/sundae-contracts \
#   nix develop -c scripts/smoke/devnet-local --phase <treasury phase>
#
# Expected live-boundary signal: orderConsumed=true, treasuryTokenQuantity>0,
# a scoop tx id, and the fresh-cascade hashes in summary.json.

git diff --check
nix develop --quiet -c just ci
