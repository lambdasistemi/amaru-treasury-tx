#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

git diff --check

frontend_shell='
let
  f = builtins.getFlake (toString '"$repo_root"');
  system = builtins.currentSystem;
  pkgs = import f.inputs.nixpkgs {
    inherit system;
    overlays = [
      f.inputs.purescript-overlay.overlays.default
      f.inputs.mkSpagoDerivation.overlays.default
    ];
  };
in pkgs.mkShell {
  packages = [
    pkgs.purs
    pkgs.spago-unstable
    pkgs.esbuild
    pkgs.nodejs_20
    pkgs.playwright-test
    pkgs.playwright-driver
  ];
  PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
}
'

nix develop --quiet --impure --expr "$frontend_shell" -c bash -lc '
  set -euo pipefail
  cd "$1"

  browser_json_tree=$(nix eval --raw --impure --expr \
    "(builtins.getFlake (toString $1)).inputs.browser-json-tree.outPath")

  vendor_root="$1/frontend/vendor"
  vendor_link="$vendor_root/browser-json-tree"
  made_vendor=0
  if [ ! -e "$vendor_link" ]; then
    mkdir -p "$vendor_root"
    ln -s "$browser_json_tree" "$vendor_link"
    made_vendor=1
  fi
  cleanup() {
    if [ "$made_vendor" = 1 ]; then
      rm -f "$vendor_link"
      rmdir "$vendor_root" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  cd frontend
  spago build
  spago test
  esbuild src/bootstrap.js \
    --bundle \
    --outfile=dist/deps.js \
    --format=iife \
    --platform=browser \
    --minify
  spago bundle --module Main --outfile dist/index.js
  cat dist/deps.js dist/index.js > dist/bundle.js
  mv dist/bundle.js dist/index.js
  rm dist/deps.js
  test -s dist/index.js
  playwright test --config test/playwright/playwright.config.ts
' bash "$repo_root"
