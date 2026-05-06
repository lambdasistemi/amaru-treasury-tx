# shellcheck shell=bash

set unstable := true

# List available recipes
default:
    @just --list

# Format Haskell, Cabal, and Nix files
format:
    #!/usr/bin/env bash
    set -euo pipefail
    find . -type f -name '*.hs' \
      -not -path '*/dist-newstyle/*' \
      -exec fourmolu -i {} +
    cabal-fmt -i amaru-treasury-tx.cabal

# Check Haskell, Cabal, and Nix file formatting
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    find . -type f -name '*.hs' \
      -not -path '*/dist-newstyle/*' \
      -exec fourmolu -m check {} +
    cabal-fmt -c amaru-treasury-tx.cabal

# Run hlint
hlint:
    #!/usr/bin/env bash
    set -euo pipefail
    find . -type f -name '*.hs' \
      -not -path '*/dist-newstyle/*' \
      -exec hlint {} +

# Check the release version contract
release-check:
    scripts/release/check-version-consistency

# Smoke-test the shipped swap-wizard signer UX
smoke:
    scripts/smoke/swap-wizard-signers

# Build all components
build:
    cabal build all -O0

# Run unit tests (optional --match pattern)
unit match="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ match }}' == "" ]]; then
        cabal test unit-tests -O0 --test-show-details=direct
    else
        cabal test unit-tests -O0 \
            --test-show-details=direct \
            --test-option=--match \
            --test-option="{{ match }}"
    fi

# Run golden tests (optional --match pattern)
golden match="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ match }}' == "" ]]; then
        cabal test golden-tests -O0 --test-show-details=direct
    else
        cabal test golden-tests -O0 \
            --test-show-details=direct \
            --test-option=--match \
            --test-option="{{ match }}"
    fi

# Full CI pipeline (build, tests, lint, format-check)
ci:
    just build
    just unit
    just golden
    just format-check
    just hlint
    just smoke
    just release-check
