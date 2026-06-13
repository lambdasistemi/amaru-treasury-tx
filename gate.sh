#!/usr/bin/env bash
set -euo pipefail

root="$(pwd -P)"

cleanup() {
    rm -f "${root}/frontend/vendor/browser-json-tree"
    rmdir "${root}/frontend/vendor" 2>/dev/null || true
    rm -f \
        "${root}/frontend/dist/index.js" \
        "${root}/frontend/dist/deps.js" \
        "${root}/frontend/dist/bundle.js" \
        "${root}/frontend/dist/json-tree.css"
}

trap cleanup EXIT

prepare_frontend_vendor() {
    local browser_json_tree
    browser_json_tree="$(
        nix eval --raw --impure --expr \
            "(builtins.getFlake (toString ${root})).inputs.browser-json-tree.outPath"
    )"
    mkdir -p "${root}/frontend/vendor"
    ln -sfn "${browser_json_tree}" \
        "${root}/frontend/vendor/browser-json-tree"
}

frontend_tools() {
    nix develop --quiet --impure --expr \
        "let
           flake = builtins.getFlake (toString ${root});
           system = builtins.currentSystem;
           pkgs = import flake.inputs.nixpkgs {
             inherit system;
             overlays = [ flake.inputs.purescript-overlay.overlays.default ];
           };
         in
           pkgs.mkShell {
             packages = [
               pkgs.purs
               pkgs.spago-unstable
               pkgs.esbuild
               pkgs.nodejs_20
             ];
           }" \
        -c "$@"
}

git diff --check
prepare_frontend_vendor

frontend_tools sh -lc '
    set -euo pipefail
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
'

nix build --quiet .#frontend
cp -f result/index.js frontend/dist/index.js
cp -f result/json-tree.css frontend/dist/json-tree.css

cd frontend
nix shell nixpkgs#playwright-test -c playwright test \
    --config test/playwright/playwright.config.ts \
    test/playwright/*.spec.ts
