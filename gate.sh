#!/usr/bin/env bash
# Mechanical gate for issue #474 (publish canonical treasury books).
# Present for the PR's life; the reviewer drops it before merge.
set -euo pipefail

git diff --check

# The book drift check is added in the slice that introduces it
# (nix/checks.nix `book`); this gate is extended there.

echo "gate: OK"
