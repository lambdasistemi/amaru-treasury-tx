#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --accept-flake-config --quiet -c just ci
