# Tasks: Devnet Treasury Swap Via Coordinator

## Slice 0 — Orchestration Bootstrap

- [X] T443-S0 Create worktree and PR-local gate.
- [X] T443-S0 Run baseline `./gate.sh`.
- [X] T443-S0 Commit spec, plan, and tasks.
- [X] T443-S0 Resolve Q-001 before implementation dispatch.

## Slice 1 — Coordinator Contract Compatibility

- [ ] T443-S1 Add RED coverage for the live coordinator
  `fee-status` response shape.
- [ ] T443-S1 Update client/workflow compatibility only if Q-001
  authorizes crossing the #442 client boundary.
- [ ] T443-S1 Run focused unit tests for coordinator client/workflow.
- [ ] T443-S1 Run `./gate.sh`.
- [ ] T443-S1 Commit `fix: align coordinator fee-status client` with
  `Tasks: T443-S1`.

## Slice 2 — Named Devnet Smoke Through Coordinator

- [ ] T443-S2 Register `treasury-swap-via-coordinator` in the devnet
  smoke runner.
- [ ] T443-S2 Start the external `cardano-multisig` coordinator from an
  executable override or its flake, with devnet #39 environment.
- [ ] T443-S2 Reuse the `treasury-swap-full-e2e` deploy, multi-owner
  roster, Sundae pool, `mkFullSwapIntent`, `swapProgram`, scoop, and
  final treasury-value helpers.
- [ ] T443-S2 Build the swap unsigned, pre-witness the requester
  fuel/collateral input, pay the coordinator fee with metadata label
  `9721`, and assert fee-status reaches ready-to-publish from
  `fee_not_seen`.
- [ ] T443-S2 Assert owner entry discovery through
  `GET /v1/entries?signer=<ownerKeyHash>` before witness upload.
- [ ] T443-S2 Upload both owner witnesses, submit through the
  coordinator, scoop the resulting order, and assert final treasury
  value.
- [ ] T443-S2 Write summary artifacts with coordinator and treasury
  evidence.
- [ ] T443-S2 Run
  `nix develop --accept-flake-config -c just devnet-smoke treasury-swap-via-coordinator`.
- [ ] T443-S2 Run `./gate.sh`.
- [ ] T443-S2 Commit `test(devnet): swap treasury through coordinator`
  with `Tasks: T443-S2`.

## Finalization

- [ ] T443-F1 Re-run `./gate.sh` at HEAD.
- [ ] T443-F1 Re-run the named live smoke and capture artifact path.
- [ ] T443-F1 Update PR body with `Closes #443` and validation evidence.
- [ ] T443-F1 Drop `gate.sh`.
- [ ] T443-F1 Mark PR ready for review.
- [ ] T443-F1 Verify GitHub Actions `CI` is green and ignore docs
  workflow.
