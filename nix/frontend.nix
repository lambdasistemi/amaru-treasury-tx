# #239 T012 — Build the Halogen dashboard bundle.
#
# Lifts the lambdasistemi house pattern from
# /code/graph-browser-view-export-import + /code/cardano-mpfs-browser:
#
#   * purescript-overlay supplies `purs`, `spago-unstable`,
#     `purs-tidy-bin.purs-tidy-0_10_0`, `purescript-language-server`.
#   * mkSpagoDerivation supplies the reproducible builder that
#     consumes `spago.yaml` + `spago.lock` offline.
#   * esbuild handles npm-side bundling (we do NOT use any npm
#     deps in v1; bootstrap.js is an empty IIFE).
#
# Outputs `$out` containing `index.html` + `index.js` (the
# bundled PureScript app). Consumed by `nix/docker.nix` (T023)
# which copies these into the image at the static-assets path.

{ pkgs, src, browserJsonTree }:

let
  # Vendor the `browser-json-tree` library source into the
  # frontend build tree so spago can resolve it via the
  # workspace `extraPackages.path` entry in `frontend/
  # spago.yaml`.  The library is pinned to an exact commit
  # at the top-level flake.nix, so this vendor copy is
  # content-addressed.
  preparedSrc = pkgs.runCommand "frontend-src-prepared" { } ''
    mkdir -p $out
    cp -r ${src}/. $out/
    chmod -R +w $out
    mkdir -p $out/vendor
    cp -r ${browserJsonTree} $out/vendor/browser-json-tree
    chmod -R +w $out/vendor
  '';
in

pkgs.mkSpagoDerivation {
  pname = "amaru-treasury-dashboard";
  version = "0.1.0";
  src = preparedSrc;
  spagoYaml = preparedSrc + "/spago.yaml";
  spagoLock = preparedSrc + "/spago.lock";
  nativeBuildInputs = [
    pkgs.purs
    pkgs.spago-unstable
    pkgs.esbuild
    pkgs.nodejs_20
  ];
  buildPhase = ''
    set -euo pipefail
    # No npm dependencies in v1, so bootstrap.js is just an
    # empty IIFE seeding `globalThis` placeholders if needed.
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
  '';
  installPhase = ''
    mkdir -p $out
    cp dist/index.html $out/
    cp dist/index.js $out/
    cp dist/material.js $out/
    cp dist/styles.css $out/
    cp dist/style-build.css $out/
    cp dist/favicon.svg $out/
    # Ship the canonical JsonTree stylesheet from the
    # browser-json-tree library; index.html links it.
    cp vendor/browser-json-tree/dist/json-tree.css $out/
  '';
}
