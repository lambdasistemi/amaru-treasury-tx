#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just build
nix develop --quiet -c just unit "Trace"
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint
