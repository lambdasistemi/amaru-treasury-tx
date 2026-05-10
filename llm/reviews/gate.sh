#!/usr/bin/env bash
set -euo pipefail

# Baseline quality gate for PR #71 / issue #70.
# Covers build, unit tests, linting, and formatting, with cheap repo checks.
nix develop --quiet -c just build
nix develop --quiet -c just unit
nix develop --quiet -c just golden
nix develop --quiet -c just schema-check
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
nix develop --quiet -c just cabal-check

git diff --check origin/main...HEAD

if [[ -d specs/070-quote-derived-swap-params ]]; then
  .specify/scripts/bash/check-prerequisites.sh --json --include-tasks >/dev/null
fi
