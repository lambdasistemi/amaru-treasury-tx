# Feature Spec: Devnet Multi-Owner Treasury Roster

Issue: #441
Parent epic: #440

## User Story

As the coordinator integration harness, I need the
`treasury-swap-full-e2e` devnet run to produce a treasury swap that
has multiple owner required signers and a separate requester-owned
fuel/collateral input, so #443 can prove real witness collection
instead of the current single-genesis-key shortcut.

## Functional Requirements

- FR-001: The devnet treasury registry used by
  `treasury-swap-full-e2e` MUST publish scope-owner datum entries
  containing at least two distinct owner key hashes derived from
  distinct deterministic seeds.
- FR-002: The smoke MUST fund each owner key address on the devnet
  using the existing genesis-funded transaction pattern.
- FR-003: The smoke MUST derive and fund a requester/fee wallet from
  a deterministic seed distinct from every owner seed.
- FR-004: The swap build MUST use requester-owned UTxO(s) for
  wallet fuel/collateral and MUST NOT use an owner key or the genesis
  key for that fuel/collateral input.
- FR-005: The swap intent passed to the existing `swapProgram` MUST
  carry at least two distinct owner required signers.
- FR-006: The smoke MUST expose the owner signing keys and requester
  signing key as run artifacts so the coordinator e2e can create
  independent witnesses.
- FR-007: The implementation MUST NOT change the swap builder,
  on-chain validators, or coordinator code.

## Acceptance Criteria

- AC-001: A focused `treasury-swap-full-e2e` devnet smoke can build
  and submit the swap with `required_signers` containing at least two
  distinct owner hashes.
- AC-002: The wallet fuel/collateral input selected for the swap is
  owned by the requester/fee wallet, and the requester key is not one
  of the owner keys.
- AC-003: The run directory contains owner and requester signing key
  artifacts or an equivalent manifest naming their paths and hashes.
- AC-004: `nix develop --quiet -c just ci` passes before the PR is
  finalized.

## Constraints

- Follow the existing devnet deploy scaffold:
  `registry-init -> stake-reward-init -> governance-withdrawal-init`.
- Derive deterministic keys using the same `mkSignKey` style used by
  `cardano-node-clients` genesis setup.
- Fund new addresses through the existing in-harness transaction
  helpers; do not add an external funding mechanism.
- Preserve existing single-owner devnet call sites unless they opt in
  to the multi-owner roster.
