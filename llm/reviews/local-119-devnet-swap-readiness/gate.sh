#!/usr/bin/env bash
set -euo pipefail

.specify/scripts/bash/check-prerequisites.sh \
  --json \
  --require-tasks \
  --include-tasks >/dev/null

git diff --check
nix develop --quiet -c just ci
