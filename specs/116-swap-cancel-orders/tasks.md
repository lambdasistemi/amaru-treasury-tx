# Tasks: Cancel Pending SundaeSwap Orders

**Input**: Design documents from `/specs/116-swap-cancel-orders/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/swap-cancel-cli.md

## Phase 1: Setup

- [X] T001 Confirm SundaeSwap V3 cancel authority and current Amaru
  order datum signer shape from SDK/spec and existing `swapOrderDatum`.
- [X] T002 Create Spec Kit artifacts for issue #116 in
  `specs/116-swap-cancel-orders/`.

## Phase 2: Foundational

- [X] T003 [P] Add RED tests for `sundaeCancelRedeemer` in
  `test/unit/Amaru/Treasury/RedeemerSpec.hs`.
- [X] T004 [P] Add RED tests for parsing Amaru order owner signers in
  `test/unit/Amaru/Treasury/Tx/SwapCancelSpec.hs`.
- [X] T005 [P] Add RED tests for rejecting unsupported or mismatched
  order datum owner/destination in
  `test/unit/Amaru/Treasury/Tx/SwapCancelSpec.hs`.
- [X] T006 Add `sundaeCancelRedeemer` to
  `lib/Amaru/Treasury/Redeemer.hs`.
- [X] T007 Add `Amaru.Treasury.Tx.SwapCancel.Datum` with safe parsing
  and validation for current Amaru SundaeSwap V3 order datums.

## Phase 3: User Story 1 - Build A Cancel Transaction (P1)

**Goal**: Build an unsigned cancellation transaction from explicit
order inputs.

**Independent Test**: draft the pure program with synthetic order value,
script reference, wallet fuel, treasury destination, and required
signers; assert body shape.

- [X] T008 [P] Add RED pure-program body-shape tests in
  `test/unit/Amaru/Treasury/Tx/SwapCancelSpec.hs`.
- [X] T009 Add `Amaru.Treasury.Tx.SwapCancel` with `SwapCancelIntent`
  and `swapCancelProgram`.
- [X] T010 Ensure the pure program spends wallet fuel, marks wallet
  collateral, spends the order script input with the cancel redeemer,
  references the order script, pays order value to treasury, and
  requires all parsed signer hashes.
- [X] T010A Add the explicit-order `swap-cancel` CLI parser,
  dispatcher, live build runner, and cancellation report output.
- [X] T011 Add focused docs for the explicit-order command path in
  `docs/swap.md`.

## Phase 4: User Story 2 - Prevent Cancelling The Wrong Order (P1)

**Goal**: reject unsafe order datum mismatches before CBOR output.

**Independent Test**: parser/validator tests fail for wrong owner,
wrong treasury script hash, malformed order datum, and unsupported owner
policy.

- [X] T012 [US2] Add validation function comparing parsed order owner
  against metadata owners.
- [X] T013 [US2] Add validation function comparing parsed destination
  against selected treasury script hash.
- [X] T014 [US2] Render stable validation diagnostics for owner,
  destination, and unsupported-policy failures.

## Phase 5: User Story 3 - Use Inspect Output As Input (P2)

**Goal**: integrate with #109 once its report contract exists.

**Blocked by #109.**

- [ ] T015 [US3] Add parser for #109 pending-order JSON report entry
  after #109 merges.
- [ ] T016 [US3] Add CLI option to select an order from inspect output
  after #109 merges.
- [ ] T017 [US3] Add integration fixture proving inspect output feeds
  the cancel command after #109 merges.

## Phase 6: Polish

- [X] T018 Run `nix develop --quiet -c just format`.
- [X] T019 Run focused tests for Redeemer and SwapCancel.
- [X] T020 Run `nix develop --quiet -c just ci` before PR/push.

## Dependencies

- T003-T007 block all cancel implementation.
- US1 can land before #109 using explicit order inputs.
- US2 depends on datum parsing from T007.
- US3 is blocked until #109 finalizes pending-order discovery output.

## Implementation Strategy

1. Implement redeemer and datum parsing first.
2. Add the pure transaction program and body-shape tests.
3. Add CLI runner only after the pure surface is stable.
4. Defer inspect-report integration until #109 is merged.
