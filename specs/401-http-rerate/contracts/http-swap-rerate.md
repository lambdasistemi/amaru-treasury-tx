# Contract: POST /v1/build/swap-rerate

## Purpose

Build unsigned swap re-rate transaction artifacts for selected pending orders in one scope. The server must not sign, submit, or persist the request.

## Request

The request must carry:

- `scope`: one treasury scope.
- `selectedOrders`: one or more pending order UTxO references, with enough order data or server-resolvable identity to build a `RerateIntent`.
- `newRate`: positive ADA/USDM rate.
- `walletTxIn`: plain-key wallet UTxO used for fees.
- `collateralTxIn`: optional plain-key collateral UTxO; defaults according to the existing CLI behavior if omitted.

The final field names should follow the existing API module naming style and be documented by the derived JSON instances/tests.

## Response

The response must include exactly one high-level outcome:

- Success with unsigned CBOR hex/envelope/report and `decision = single_tx`.
- Split fallback with `decision = split`, reason, estimate, and split groups.
- Typed failure with stable tag and human-readable reason.

## Typed Failure Families

- Off-scope selected order.
- Over budget with no valid split.
- Value-conservation or build failure.
- Malformed input, including empty order list and non-positive rate.

## Non-Goals

- Signing.
- Submission.
- UI state.
- Cross-scope batches.
