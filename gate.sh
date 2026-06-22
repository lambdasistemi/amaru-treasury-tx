#!/usr/bin/env bash
set -euo pipefail

git diff --check
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
nix develop --quiet -c just ci
