#!/usr/bin/env bash
# Mechanical gate for issue #474 (publish canonical treasury books).
# Present for the PR's life; the reviewer drops it before merge.
set -euo pipefail

git diff --check

# Book drift check (#474): regenerate the published overlay book from the
# vendored canonical journal metadata and fail closed if the committed
# asset (docs/assets/amaru-treasury-book.ttl) diverges from regeneration.
nix build --quiet .#checks.x86_64-linux.book

echo "gate: OK"
