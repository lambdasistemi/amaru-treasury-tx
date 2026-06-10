#!/usr/bin/env bash
set -euo pipefail
nix build --quiet .#frontend .#amaru-treasury-tx-api \
  .#checks.x86_64-linux.unit .#checks.x86_64-linux.golden
