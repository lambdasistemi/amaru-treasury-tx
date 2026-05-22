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

{ pkgs, src }:

pkgs.mkSpagoDerivation {
  pname = "amaru-treasury-dashboard";
  version = "0.1.0";
  inherit src;
  spagoYaml = src + "/spago.yaml";
  spagoLock = src + "/spago.lock";
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
  '';
}
