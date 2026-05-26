#!/usr/bin/env bash
# Mechanical gate for PR #299 (Playwright-driven UI review:
# md-icon + theme-toggle a11y + mobile topbar polish). Every reviewed
# slice must pass this before the orchestrator accepts the commit,
# and the finalization audit re-runs it at HEAD.
#
# Frontend-only ticket: no Haskell changes, no backend impact.
# Hence we skip just unit/golden/format-check/hlint/smoke and rely
# on `nix build .#frontend` to compile the PureScript bundle.
# The Playwright after-capture is an orchestrator-side proof, not a
# driver-side gate step (needs network + dev deploy).
#
# See gate-script skill ("Extended by the orchestrator").
set -euo pipefail

git diff --check
nix build --quiet --no-link .#frontend
