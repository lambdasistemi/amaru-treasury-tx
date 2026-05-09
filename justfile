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

# Regenerate the TreasuryIntent JSON Schema asset
update-schema:
    cabal run -v0 -O0 exe:amaru-treasury-intent-schema \
        > docs/assets/intent-schema.json
    cabal run -v0 -O0 exe:amaru-treasury-report-schema \
        > docs/assets/tx-report-schema.json

# Check that the committed TreasuryIntent JSON Schema is current
schema-check:
    #!/usr/bin/env bash
    set -euo pipefail
    intent_tmp="$(mktemp)"
    report_tmp="$(mktemp)"
    trap 'rm -f "$intent_tmp" "$report_tmp"' EXIT
    cabal run -v0 -O0 exe:amaru-treasury-intent-schema > "$intent_tmp"
    diff -u docs/assets/intent-schema.json "$intent_tmp"
    cabal run -v0 -O0 exe:amaru-treasury-report-schema > "$report_tmp"
    diff -u docs/assets/tx-report-schema.json "$report_tmp"

# Smoke-test the shipped CLI surface
smoke:
    scripts/smoke/swap-wizard-signers
    scripts/smoke/swap-quote-override
    scripts/smoke/withdraw-wizard-zero-rewards
    scripts/smoke/withdraw-wizard-pipe
    scripts/smoke/tx-build-pipe

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

# Run red-step (TDD-pre-impl) tests. Expected to FAIL until the
# corresponding green-step task lands. Not part of `just ci` /
# `nix build .#checks.unit`. Use `--match` to focus a single
# assertion (e.g. `just red "FR-001"`).
red match="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ match }}' == "" ]]; then
        cabal test red-tests -O0 --test-show-details=direct
    else
        cabal test red-tests -O0 \
            --test-show-details=direct \
            --test-option=--match \
            --test-option="{{ match }}"
    fi

# Full CI pipeline (build, tests, lint, format-check)
ci:
    just build
    just schema-check
    just unit
    just golden
    just format-check
    just hlint
    just smoke
    just release-check

# Cabal check (Hackage-readiness gate, per /haskell skill)
cabal-check:
    cabal check --ignore=missing-upper-bounds \
        --ignore=no-modules-exposed \
        --ignore=option-o2
