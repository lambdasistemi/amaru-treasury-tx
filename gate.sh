#!/usr/bin/env bash
set -euo pipefail

# PR lifecycle gate for #413 (treasury swap e2e on devnet — FULL pipeline:
# deployed treasury + swapProgram debit; design B, follow-up to #409).
# Mirrors the repo convention (cf. #400, #409): the pre-commit hook execs
# this file while it exists, so every behaviour-changing commit must pass
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
#   SUNDAE_CONTRACTS_DIR=/tmp/attx-413/sundae-contracts \
#   nix develop -c scripts/smoke/devnet-local --phase treasury-swap-full-e2e
#
# Expected live-boundary signal (summary.json): orderConsumed=true,
# treasuryTokenQuantity>0, treasury debited by swapAmount+overhead, a
# swapProgram order tx id, the scoop tx id, and the re-rooted cascade +
# treasury hashes / deploy anchors.

git diff --check
nix develop --quiet -c just ci
