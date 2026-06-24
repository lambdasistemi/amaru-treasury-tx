#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git diff --check
nix develop --quiet -c just build
nix develop --quiet -c just unit "CliDevnetSmoke"
nix develop --quiet -c just format-check
