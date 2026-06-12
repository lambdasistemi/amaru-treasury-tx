#!/usr/bin/env bash
# Mechanical gate for the #366 PR (stateless attach + submit
# endpoints). Present for the PR's life; dropped in the final
# `chore: drop gate.sh` commit before mark-ready.
set -euo pipefail

git diff --check
nix develop --quiet -c just build

# Unit suite. The history-RDF tests (Amaru.Treasury.Api.Ttl,
# Amaru.Treasury.Api.Proofs) shell out to `cq-rdf` + Apache Jena
# (`arq`/`shacl`); per flake.nix those live in `rdfRuntimeInputs` and
# are wired only into the hermetic `nix flake check` unit derivation,
# NOT this host's `nix develop` shell. They are red on `main` here for
# lack of that tooling and are entirely unrelated to #366 (attach /
# submit do no RDF). They remain covered by CI's hermetic unit check.
# Skip exactly those describe-paths in the local per-commit gate;
# everything else must pass.
nix develop --quiet -c cabal test unit-tests -O0 \
    --test-show-details=direct \
    --test-option=--skip --test-option="Amaru.Treasury.Api.Ttl" \
    --test-option=--skip --test-option="Amaru.Treasury.Api.Proofs"

nix develop --quiet -c just format-check
nix develop --quiet -c just hlint

# Ticket-specific focused proof added by implementation slices:
#   nix develop --quiet -c just unit "Attach"
#   nix develop --quiet -c just unit "Submit"
