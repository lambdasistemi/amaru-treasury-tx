# Feature Specification: Operate UI Re-rate Mode

## User Story

As a treasury operator on `/operate`, I can choose **Re-rate** as a
top-level operation beside Swap, Disburse, and Reorganize, choose one
scope, select the scope's pending SundaeSwap orders to retract, enter a
new rate, and build the unsigned re-rate transaction through the
existing `/v1/build/swap-rerate` endpoint.

## Acceptance Criteria

- The operation selector exposes `Re-rate` as a peer segment, backed by
  a new `ModeRerate` constructor in `TxMode`.
- Re-rate mode fetches pending orders from `/v1/pending?scope=<scope>`
  and shows the selected scope's `PendingSwapOrder` rows.
- Each pending order row can be selected or unselected for retraction.
- The form carries a positive new-rate input and the wallet/collateral
  inputs needed by the #401 endpoint.
- Building posts the request body expected by
  `SwapRerateBuildRequest`: `srrScope`, `srrSelectedOrders`,
  `srrNewRate`, `srrWalletTxIn`, and `srrCollateralTxIn`.
- The preview reads the `srr*` response prefix, including
  `srrCborHex`, `srrDecision`, `srrReason`, `srrReport`,
  `srrFailureTag`, and `srrFailureReason`.
- A split response is visible as a non-CBOR build result with the
  split decision and reason in the existing preview/status surface.
- When the selected scope has no pending orders, the form renders a
  clear empty state and does not allow a re-rate build.
- `frontend/src/Api.purs` maps `/v1/build/swap-rerate` to
  `srrCborHex` for rebuild and pending-entry support.
- The gate builds the frontend and runs a Playwright test that renders
  Re-rate mode end-to-end.
- `frontend/test/Test/Main.purs` and Playwright cover orders-present
  selection, over-budget split rendering, and no-orders empty state.
- A screenshot of the working Re-rate mode is committed under
  `frontend/test/ui-review/402/`.

## Non-Goals

- No backend changes under `lib/`, `app/`, or API route definitions.
- No signing, witness collection, or submission changes.
- No docs changes for #403.
- No market automation or rate recommendation logic.

## Notes

The backend endpoint is already merged on `origin/main` via #401. The
current route and JSON contract are read-only for this ticket.
