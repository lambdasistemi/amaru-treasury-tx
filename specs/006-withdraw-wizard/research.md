# Phase 0 Research: Withdraw Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-07

## R1. Release command shape

**Decision**: Use `withdraw-wizard | tx-build`, not
`withdraw-wizard | withdraw`.

**Rationale**: Feature 005 made `tx-build` the release-facing builder
for every action. Reintroducing a per-action `withdraw` command would
undo the unified dispatcher and duplicate the network-mismatch, stdin,
logging, and schema handling.

**Alternatives considered**:

- Keep issue #45's original `withdraw` subcommand wording: rejected as
  stale after feature 005.
- Add `withdraw` as an alias to `tx-build`: rejected for this feature;
  aliases create two public paths to document and test.

## R2. Withdraw payload fields

**Decision**: Replace placeholder `WithdrawInputs` with:

```haskell
data WithdrawInputs = WithdrawInputs
    { wiTreasuryRewardAccount :: Text
    , wiRewardsLovelace :: Integer
    }
```

The reward account is encoded as the 28-byte treasury script hash /
stake credential hash, matching the current `parseRewardAccount`
style; the parser must become network-aware before preprod use.

**Rationale**: The shared `scope` block already carries the treasury
contract address and deployed references, but it does not carry the
treasury reward account or current reward amount. Those two values are
withdraw-specific and belong under the `withdraw` payload block.

**Alternatives considered**:

- Put `treasuryRewardAccount` into shared `ScopeJSON`: rejected because
  swap/disburse/reorganize do not need it.
- Encode a bech32 stake address: deferred. The existing JSON helper
  expects 28-byte script-hash text; changing all reward-account fields
  should be a separate schema decision.

## R3. Zero rewards behavior

**Decision**: `withdraw-wizard` exits 0 and writes no intent when the
resolved reward balance is zero.

**Rationale**: Upstream `withdraw.sh` exits 0 for "nothing to withdraw"
and does not produce a transaction. Preserving that behavior prevents
operators from signing a no-op or misleading artifact.

**Alternatives considered**:

- Emit a zero-rewards intent and let `tx-build` fail: rejected because
  it creates an artifact that is known unusable at production time.
- Exit non-zero: rejected because "nothing to withdraw" is an expected
  no-op state, not an operational failure.

## R4. Synthetic golden before live preprod oracle

**Decision**: Ship a synthetic frozen withdraw golden first. Track the
live preprod oracle under issue #17.

**Rationale**: Mainnet reward balances are currently zero in the issue
context. A positive on-chain withdraw requires registering/delegating a
preprod treasury reward account and waiting for rewards. The builder can
still be tested with a frozen `ChainContext` and operator-supplied
`rewardsLovelace`, because the transaction shape is independent of the
source of that number.

**Alternatives considered**:

- Block the feature until live rewards accrue: rejected because it
  prevents schema, wizard, and builder integration work.
- Skip golden evidence: rejected by Constitution V.

## R5. `withdraw.sh` withdrawal amount discrepancy

**Decision**: Treat the discrepancy as an implementation gate. Before
the builder lands, verify whether the faithful Haskell transaction
should encode withdrawal amount `0` (as the bash command line says) or
the positive reward amount (as the existing pure builder does).

**Rationale**: `journal/2026/bin/withdraw.sh` queries
`rewardAccountBalance`, pays that amount to the treasury output, but
passes `--withdrawal <stake>+0` to `cardano-cli`. Existing
`withdrawProgram` withdraws the positive `wiRewardsAmount`. The tasks
must include a RED check that makes this decision explicit rather than
silently preserving either behavior.

**Alternatives considered**:

- Assume the existing Haskell builder is correct: rejected without
  oracle evidence.
- Assume bash `+0` is intentional: rejected because the output pays the
  positive reward balance.

## R6. Required signers

**Decision**: Encode `signers = []` for withdraw intents unless a later
oracle proves a required signer hash is needed.

**Rationale**: The withdraw purpose in the existing pure builder does
not add required signer hashes or permissions co-approval. The wallet
fuel input still requires an external payment witness when signing, but
that is not the same as the transaction body's `required_signers` set.

**Alternatives considered**:

- Include the scope owner by convention: rejected because it would
  change the transaction body and diverge from the existing builder.

## R7. Network-aware reward-account parsing

**Decision**: Add a network-aware reward-account parser or constructor
as part of the withdraw feature before any preprod fixture is trusted.

**Rationale**: The current helper constructs `AccountAddress Mainnet`
from a 28-byte script hash. Withdraw is the first feature whose
acceptance path explicitly depends on preprod rewards. Mainnet-hardcoded
reward accounts would make preprod goldens misleading.

**Alternatives considered**:

- Defer to issue #32: rejected for the withdraw feature because it
  directly blocks credible preprod validation.
