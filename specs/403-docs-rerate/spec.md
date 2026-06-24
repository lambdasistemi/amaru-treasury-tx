# Issue 403 Specification: Worked Swap Re-rate Workflow

## Goal

Document the shipped swap re-rate workflow for treasury operators across
the CLI, HTTP API, and Operate UI. The page must describe the current
address-based funding contract: the operator supplies a wallet address,
and the system selects wallet fuel, collateral, and change using the
same selection path as Swap.

## P1 User Story

As a treasury operator, I can follow one worked guide to discover
pending scope orders, choose the orders to re-rate, supply a new rate
and wallet address, build the unsigned re-rate result, understand
whether the build is a single atomic transaction or a split fallback,
then continue through review, witness collection, and submission.

## Functional Requirements

- FR-001 The docs add a `docs/` page for swap re-rate and include it in
  `mkdocs.yml` navigation.
- FR-002 The README links the new page from the documentation section.
- FR-003 The page covers all three operator surfaces:
  `swap-rerate` CLI, `POST /v1/build/swap-rerate`, and Operate UI
  Re-rate mode.
- FR-004 The page states that re-rate funding is wallet-address based,
  not manual wallet/collateral tx-in entry.
- FR-005 The page documents the single-transaction preferred path and
  the split fallback when ExUnits or transaction size budgets are
  exceeded.
- FR-006 The page documents the value rule: each new order clears
  minUTxO and re-funds the Sundae scooper rider; offered amount is
  conserved and the wallet covers transaction fees.
- FR-007 The page cross-links the existing standalone `swap-cancel`
  workflow, the HTTP endpoint, the Operate UI screenshot, and epic
  #395.
- FR-008 The docs gate includes `mkdocs build --strict` so broken links
  fail locally and in the PR workflow.

## Non-goals

- No code changes.
- No changes to shipped CLI, API, frontend, tests, fixtures, or Nix
  dependency pins.
- No new screenshots or generated frontend assets.

## Success Criteria

- `mkdocs build --strict` succeeds.
- `./gate.sh` succeeds before final PR readiness.
- The PR is ready for review with every `T403-*` task checked.
