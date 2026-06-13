#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

git diff --check

browser_json_tree="$(
  nix build --quiet --no-link --print-out-paths \
    github:lambdasistemi/browser-json-tree/970657fd515259d8ba745fbb82a3a43fc9531b08
)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/frontend"
cp -R frontend/. "$tmp/frontend/"
mkdir -p "$tmp/frontend/vendor"
cp -R "$browser_json_tree" "$tmp/frontend/vendor/browser-json-tree"
chmod -R +w "$tmp/frontend"

nix shell --quiet \
  github:paolino/purescript-overlay/fix/remove-nodePackages#purs \
  github:paolino/purescript-overlay/fix/remove-nodePackages#spago-unstable \
  nixpkgs#esbuild \
  nixpkgs#nodejs_20 \
  --command bash -euo pipefail -c '
    cd "$1"
    spago test
    esbuild src/bootstrap.js \
      --bundle \
      --outfile=dist/deps.js \
      --format=iife \
      --platform=browser \
      --minify
    spago bundle --offline --module Main
    cat dist/deps.js dist/index.js > dist/bundle.js
    mv dist/bundle.js dist/index.js
    rm dist/deps.js
  ' bash "$tmp/frontend"

nix build --quiet --no-link .#frontend .#checks.x86_64-linux.frontend-bundle

nix develop --quiet github:paolino/dev-assets?dir=playwright \
  -c bash -euo pipefail -c '
    cd "$1"
    playwright test --config test/playwright/playwright.config.ts
  ' bash "$tmp/frontend"
