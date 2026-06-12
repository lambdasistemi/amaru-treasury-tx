#!/usr/bin/env bash
# Mechanical gate for the #365 PR (stateless tx-introspect +
# verify-witness endpoints). Present for the PR's life; dropped in
# the final `chore: drop gate.sh` commit before mark-ready.
set -euo pipefail

git diff --check
nix develop --quiet -c just build
nix develop --quiet -c just unit
nix develop --quiet -c just format-check
nix develop --quiet -c just hlint

# Ticket-specific focused proof (cheap re-run of the new specs):
#   nix develop --quiet -c just unit "Introspect"
#   nix develop --quiet -c just unit "VerifyWitness"
