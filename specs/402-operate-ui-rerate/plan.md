# Implementation Plan: Operate UI Re-rate Mode

## Stack

- PureScript Halogen frontend in `frontend/src/OperatePage.purs`.
- HTTP client helpers in `frontend/src/Api.purs`.
- Existing Playwright setup under `frontend/test/playwright/`.
- Existing Nix frontend derivation `.#frontend`.

## Backend Contract

Pending orders are available from:

```text
GET /v1/pending?scope=<scope>
```

The response is `PendingResponse`, with `entries[].orders[]` rows:

```json
{
  "outref": { "txId": "<hex>", "ix": 0 },
  "lovelaceIn": 123000000,
  "minUsdmOut": 456000000,
  "sundaeFeeLovelace": 2500000
}
```

Build requests post to:

```text
POST /v1/build/swap-rerate
```

with the `SwapRerateBuildRequest` Generic JSON shape:

```json
{
  "srrScope": "core_development",
  "srrSelectedOrders": ["<txid>#0"],
  "srrNewRate": 0.42,
  "srrWalletTxIn": "<txid>#1",
  "srrCollateralTxIn": null
}
```

Responses use the `srr` prefix:

```json
{
  "srrCborHex": "...",
  "srrCborEnvelope": "...",
  "srrReport": "...",
  "srrDecision": "single_tx",
  "srrReason": "RerateWithinBudget",
  "srrFailureTag": null,
  "srrFailureReason": null
}
```

For split outcomes, the endpoint returns `srrDecision: "split"` with a
reason and report but no `srrCborHex`.

## Slices

### Slice 1: API and Test Surface

Add PureScript client types/functions for `/v1/pending`, wire
`/v1/build/swap-rerate` into `buildCborField`, and add pure test helper
coverage for outref rendering, request JSON, split summary, and empty
pending-order classification.

### Slice 2: Re-rate Form and Preview

Add `ModeRerate`, state fields, actions, validation, form sections,
request JSON, endpoint routing, response prefix, draft serialization,
pending-order fetch on initialize/scope/mode changes, and rendering for
orders-present and empty states.

### Slice 3: Browser Gate and Evidence

Add a Playwright spec that serves the built frontend, mocks
`/v1/pending` and `/v1/build/swap-rerate`, renders Re-rate mode, proves
order selection, proves split reason rendering, proves no-orders empty
state, and writes a committed screenshot under
`frontend/test/ui-review/402/`.

## Gate

The ticket gate must run:

```bash
git diff --check
nix develop --quiet -c just ci
nix build --quiet .#frontend
```

After Slice 3 lands, it must also run the Re-rate Playwright spec
against the Nix-built frontend output.

## Risks

- The frontend dev shell does not currently expose Playwright; the
  gate should run Playwright via Nix rather than a floating npm install.
- `just ci` is Haskell-only and cannot prove PureScript compilation.
- `frontend/dist` is tracked as static shell/assets, but tests for this
  ticket must exercise the Nix-built `.#frontend` output so the latest
  PureScript source is rendered.
