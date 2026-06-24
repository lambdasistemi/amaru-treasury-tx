#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just ci

frontend_out="$(nix build --quiet --print-out-paths .#frontend)"
if [ -f frontend/test/playwright/rerate-mode.spec.ts ]; then
  AMARU_TREASURY_DIST="$frontend_out" \
    nix shell --quiet nixpkgs#nodejs_20 nixpkgs#playwright-test \
      --command playwright test \
        --config frontend/test/playwright/playwright.config.ts \
        frontend/test/playwright/rerate-mode.spec.ts
else
  echo "rerate Playwright spec not present yet; frontend build passed"
fi
