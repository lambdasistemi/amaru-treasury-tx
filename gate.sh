#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just ci
nix develop github:paolino/dev-assets?dir=mkdocs --quiet \
    -c mkdocs build --strict --site-dir site
