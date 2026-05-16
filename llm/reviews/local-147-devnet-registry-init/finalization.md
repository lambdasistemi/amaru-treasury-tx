# Finalization

state: ReadyForExternalReview

## Completed Scope

- Spec Kit artifacts created for #147.
- Draft PR #152 opened and updated.
- Production-backed registry initiator added under
  `Amaru.Treasury.Devnet.RegistryInit`.
- `registry-init` DevNet smoke phase added.
- Live local DevNet proof recorded in `runs/devnet/20260516T184944Z`.
- README and local DevNet docs updated with usage, artifacts, evidence,
  and explicit #148/#149/#150 exclusions.

## Verification

- `scripts/smoke/devnet-local --phase registry-init --run-dir /tmp/tmp.gbzyVXpWqB`
  -> RED exit 64 before implementation.
- `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"`
  -> 5 examples, 0 failures.
- `nix develop --quiet -c cabal build test:devnet-tests -O0` -> pass.
- `nix develop --quiet -c just devnet-smoke registry-init` -> pass,
  2 examples, 0 failures, run `runs/devnet/20260516T184944Z`.
- `./llm/reviews/local-147-devnet-registry-init/gate.sh` -> pass with
  Spec Kit prerequisites, `git diff --check`, build, schema-check,
  415 unit examples, 25 golden examples with 1 pending, format-check,
  hlint, smoke scripts, and release-check.

## Live Evidence

- Seed split tx:
  `f31917b80a3649c90bead84e5aea925d68945021a811f0dc68bd7dcce372a90b`.
- Registry mint tx:
  `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912`.
- Reference scripts tx:
  `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c`.
- Scopes anchor:
  `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912#0`.
- Registry anchor:
  `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912#1`.
- Permissions reference:
  `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c#0`.
- Treasury reference:
  `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c#1`.

## Boundary

This PR proves registry/reference-script publication only. It does not
claim staking/reward setup (#148), governance funding and treasury
withdrawal setup (#149), or disburse action/beneficiary receipt (#150).
