# Contract: final Phase-1 validation after reward-state bump

## Owner

`lib/Amaru/Treasury/Build/Common.hs` owns
`validateFinalPhase1`.

## Precondition

- A build runner has produced a final unsigned `ConwayTx`.
- The runner has a sampled `ChainContext`.
- Signing has not happened yet, so missing vkey witness failures may be
  present.

## Required Behavior

1. Call `Cardano.Tx.Validate.validatePhase1` for every final transaction,
   including transactions whose body contains withdrawals.
2. If validation succeeds, return `Right ()`.
3. If validation fails only because of witness-completeness failures,
   return `Right ()`.
4. If validation fails for any non-witness ledger rule, return `Left`
   with a diagnostic that includes the sampled slot and the structural
   failures.

## Forbidden Behavior

- Do not return success solely because `withdrawals` is non-empty.
- Do not remove the witness-completeness filter.
- Do not treat `ccEvaluateTx` exec-unit checks as a replacement for
  final Phase-1 validation.

## Governance Withdrawal Init Disposition

`lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` must be
reassessed after the dependency bump:

- If existing proposal and materialization fixtures pass the active
  validation path, remove `materializeResultSkipPhase1` and use
  `materializeResult`.
- If a fixture still fails for a residual ledger rule, retain only the
  narrow skip and document the exact rule plus upstream issue before
  proceeding.

## Verification

- Focused Hspec proof for withdrawal-bearing final Phase-1 validation.
- Existing governance-withdrawal-init unit/golden fixtures.
- `./gate.sh`.
- `nix flake check` before ready-for-review.
