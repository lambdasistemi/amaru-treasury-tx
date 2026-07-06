# Feature Specification: Devnet Treasury Swap Via Coordinator

**Feature Branch**: `feat/e2e-swap-via-coordinator`
**Issue**: #443
**Parent Epic**: #440
**Created**: 2026-07-06
**Status**: Ready for implementation; Q-001 answered on 2026-07-06

## User Story

As an Amaru treasury operator, I need a named devnet smoke that
drives a treasury ADA/USDM swap through the `cardano-multisig`
coordinator, so the demo path proves witness collection, fee payment,
submission, and Sundae settlement against a live local chain.

## Acceptance Criteria

- The smoke is invokable as a named phase:
  `just devnet-smoke treasury-swap-via-coordinator`.
- The smoke boots the existing local devnet on network magic 42.
- The smoke deploys the multi-owner treasury roster from #441, with at
  least two distinct owners and a separately funded requester / fee
  wallet.
- The smoke starts the `cardano-multisig` coordinator from the external
  `/code/cardano-multisig` flake, or an operator-supplied equivalent,
  against the same node socket.
- The coordinator receives a funded fee address and uses the devnet run
  configuration added by cardano-multisig#39.
- The swap transaction is built from the same `swapProgram` /
  `mkFullSwapIntent` path used by `treasury-swap-full-e2e`.
- The requester pre-witnesses the fuel/collateral input before publish.
- The #442 coordinator client path is used for quote, fee payment,
  fee-status polling, publish, owner witness upload, and submit.
- The fee payment is a live `cardano-cli` transaction carrying metadata
  label `9721`, lands on the devnet, is indexed by the coordinator,
  and drives fee-status from `fee_not_seen` to ready-to-publish.
- Each owner can discover the entry through
  `GET /v1/entries?signer=<ownerKeyHash>` using the coordinator's
  signer-controlled filter.
- Both owner witnesses are collected through the coordinator and the
  coordinator submits the assembled transaction.
- The Sundae scooper settles the order with `scoopTreasurySwapOrder`.
- Final treasury value is asserted with `treasuryFullSwapValue`.
- The smoke writes a summary artifact under the run directory with
  coordinator evidence, fee-status evidence, owner witness evidence,
  submit receipt, scoop evidence, and final treasury value.

## Live Boundary

This ticket is the live-boundary proof for #442 A-001. Unit tests can
prove request shapes, but only this smoke proves that:

- `cardano-cli` builds an acceptable fee transaction,
- metadata label `9721` is encoded in the format the coordinator
  indexer decodes,
- the payment reaches the fee address with enough lovelace,
- the coordinator indexer observes and confirms it,
- `fee-status` becomes ready-to-publish before publish.

## Constraints

- Do not change swap builder or on-chain logic.
- Do not vendor code from `cardano-multisig`.
- Do not push or merge to `main`.
- Use Q-files for parent decisions.
- Q-001 resolved that #443 owns the #442 coordinator client
  fee-status compatibility fix because the live boundary exposed a
  real wire-contract bug.
