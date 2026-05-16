# Finalization

state: ReadyForExternalReview

## Current Scope

- Issue #147 now exposes a shipped DevNet registry-init command:
  `amaru-treasury-tx --network devnet --node-socket <socket> devnet
  registry-init --funding-address <addr_test...> --signing-key-file
  <payment.skey> --run-dir <run-dir>`.
- The command calls `Amaru.Treasury.Devnet.RegistryInit`; transaction
  construction is not duplicated in CLI glue or smoke code.
- `just devnet-smoke registry-init` proves the same command runner path
  on a live local DevNet.
- README, local DevNet docs, quickstart, contracts, tasks, review
  state, and PR metadata align on the delivered command and proof path.

## Reviewed Slices

- `b9106a5d1641601536604dae409851708165516b`: production registry
  initiator extraction, approved in
  `llm/reviews/local-147-devnet-registry-init/b9106a5d1641601536604dae409851708165516b.md`.
- `a5e74d83ff46474f125d0501a9ab357d01785f2a`: live registry-init
  artifact and smoke proof, approved in
  `llm/reviews/local-147-devnet-registry-init/a5e74d83ff46474f125d0501a9ab357d01785f2a.md`.
- `663c0e2fd57d54a2cf2c8c669b31f209ada26451`: shipped
  `amaru-treasury-tx devnet registry-init` command, approved in
  `llm/reviews/local-147-devnet-registry-init/663c0e2fd57d54a2cf2c8c669b31f209ada26451.md`.

## Verification

- `git diff --check` -> pass.
- `nix develop --quiet -c just unit "registry-init command"` -> 3
  examples, 0 failures.
- `nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0` ->
  pass.
- `nix develop --quiet -c cabal build test:devnet-tests -O0` -> pass.
- Focused `fourmolu -m check` on touched Haskell files -> pass.
- `nix develop --quiet -c cabal-fmt -c amaru-treasury-tx.cabal` ->
  pass.
- `nix develop --quiet -c just hlint` -> pass, `No hints`, after
  Dalton's HLint-only amend.
- `nix develop --quiet -c just devnet-smoke registry-init` -> pass, 2
  examples, 0 failures, run `runs/devnet/20260516T193404Z`.
- `./llm/reviews/local-147-devnet-registry-init/gate.sh` -> pass after
  command slice and documentation updates.

## Live Evidence

- Seed split tx:
  `82b1f12f0ceeae86c50753a61528599c4d7b8ccef769a56accd3011c0e24084d`.
- Registry mint tx:
  `1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9`.
- Reference scripts tx:
  `5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44`.
- Scopes anchor:
  `1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#0`.
- Registry anchor:
  `1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#1`.
- Permissions reference:
  `5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#0`.
- Treasury reference:
  `5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#1`.

## Boundary

This PR proves registry/reference-script publication only. It does not
claim staking/reward setup (#148), governance funding and treasury
withdrawal setup (#149), disburse action/beneficiary receipt (#150),
swap/order execution, or external-role transaction behavior.

## Parent Carry-Forward

For #148, #149, and #150, the shipped operator command must be the P1
story before implementation handoff. Smoke proof is evidence for that
command, not a replacement for it.
