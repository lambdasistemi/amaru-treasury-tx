#!/usr/bin/env bash
set -euo pipefail

# CI-equivalent project gate from .github/workflows/ci.yml and justfile.
nix develop --quiet -c just ci
nix develop --quiet -c just cabal-check

# Pull-request docs workflow gate from .github/workflows/deploy-docs.yml.
nix develop github:paolino/dev-assets?dir=mkdocs --quiet \
  -c mkdocs build --strict --site-dir site

# Speckit planning sanity for this branch. Keep it conditional so the
# same gate can also run on the upstream base before the feature dir exists.
if [[ -d specs/006-withdraw-wizard ]]; then
  .specify/scripts/bash/check-prerequisites.sh --json --include-tasks >/dev/null
fi

# Generic whitespace/conflict-marker check on the PR delta.
git diff --check origin/main...HEAD
