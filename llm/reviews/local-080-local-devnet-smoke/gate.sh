#!/usr/bin/env bash
set -euo pipefail

.specify/scripts/bash/check-prerequisites.sh \
  --json \
  --require-tasks \
  --include-tasks >/dev/null

nix develop --quiet -c just ci
nix develop --quiet -c just devnet-smoke governance
