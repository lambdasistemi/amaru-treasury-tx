#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND="$ROOT/frontend"
PS_TOOLS=(
  github:paolino/purescript-overlay/fix/remove-nodePackages#purs
  github:paolino/purescript-overlay/fix/remove-nodePackages#spago-unstable
  nixpkgs#esbuild
)

if [ "${1:-}" != "--inside-frontend-tools" ]; then
  exec nix shell --quiet "${PS_TOOLS[@]}" -c "$0" --inside-frontend-tools
fi

cleanup_vendor=false
cleanup_dist=false

cleanup() {
  if [ "$cleanup_vendor" = true ]; then
    rm -rf "$FRONTEND/vendor"
  fi
  if [ "$cleanup_dist" = true ]; then
    rm -f "$FRONTEND/dist/deps.js" "$FRONTEND/dist/bundle.js"
  fi
}
trap cleanup EXIT

prepare_vendor() {
  if [ -e "$FRONTEND/vendor/browser-json-tree" ]; then
    return
  fi

  local source_path
  source_path="$(
    cd "$ROOT"
    nix eval --impure --raw --expr '
      let
        lock = builtins.fromJSON (builtins.readFile ./flake.lock);
        node = lock.nodes."browser-json-tree".locked;
      in
        builtins.fetchTree {
          type = node.type;
          owner = node.owner;
          repo = node.repo;
          rev = node.rev;
          narHash = node.narHash;
        }
    '
  )"

  mkdir -p "$FRONTEND/vendor"
  ln -s "$source_path" "$FRONTEND/vendor/browser-json-tree"
  cleanup_vendor=true
}

run_frontend() {
  cd "$FRONTEND"
  prepare_vendor

  spago build

  if [ -f test/Test/Main.purs ]; then
    spago test
  else
    echo "spago test: skipped until test/Test/Main.purs exists"
  fi

  esbuild src/bootstrap.js \
    --bundle \
    --outfile=dist/deps.js \
    --format=iife \
    --platform=browser \
    --minify
  cleanup_dist=true
  spago bundle --module Main
  cat dist/deps.js dist/index.js > dist/bundle.js
  mv dist/bundle.js dist/index.js

  if [ -f test/playwright/pending-store-persistence.spec.ts ]; then
    nix develop github:paolino/dev-assets?dir=playwright --quiet \
      -c playwright test \
      --config test/playwright/playwright.config.ts \
      test/playwright/pending-store-persistence.spec.ts
  else
    echo "playwright persistence: skipped until harness exists"
  fi
}

git -C "$ROOT" diff --check
run_frontend
