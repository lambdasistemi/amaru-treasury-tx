#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just ci
nix develop --quiet -c just unit "CLI DevNet smoke static guard (#161)"
nix develop --quiet -c just devnet-cli-smoke --phase full --timeout-seconds 900
