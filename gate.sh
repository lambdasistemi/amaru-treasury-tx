#!/usr/bin/env bash
# Mechanical gate for the feat/472-book-export PR.
# Present for the PR's life; dropped in the final commit before mark-ready.
set -euo pipefail

git diff --check

nix develop --quiet --command bash -c '
  set -euo pipefail
  just build
  just unit
  just golden
  just format-check
  just hlint
  just smoke
'
