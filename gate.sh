#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just ci

frontend_out="$(nix build --quiet --no-link --print-out-paths .#frontend)"
nix shell --quiet nixpkgs#playwright-test -c \
  bash -lc \
  "cd frontend && AMARU_TREASURY_DIST='$frontend_out' playwright test --config test/playwright/playwright.config.ts test/playwright/rerate-mode.spec.ts"

test -s frontend/test/ui-review/419/419-rerate-operate-desktop-1280.png
