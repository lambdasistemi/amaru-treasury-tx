# Issue 419: Re-rate Address-Based Funding

## P1 User Story

As a treasury operator, I provide a wallet address for a re-rate
exactly as I do for a Swap, and the system resolves the fee fuel plus
collateral UTxOs automatically. I never hand-pick `TXHASH#IX` for the
interactive re-rate path.

## Problem

Swap already asks for a wallet address and resolves funding with the
shared `selectWallet` / `selectTreasury` selection logic in
`Amaru.Treasury.Tx.SwapWizard`. Re-rate regressed the operator
experience by asking for a wallet fuel tx-in and optional collateral
tx-in across the CLI, the `/v1/build/swap-rerate` endpoint, and the
Operate UI.

## Requirements

- FR-001: The live re-rate runner accepts a wallet bech32 address and
  queries that address for candidate wallet UTxOs.
- FR-002: The live re-rate runner reuses `selectWallet` from
  `Amaru.Treasury.Tx.SwapWizard` to select the head wallet UTxO and any
  extra wallet fuel UTxOs. It must not reimplement largest-first
  selection.
- FR-003: The selected wallet head is used as the transaction wallet
  input and collateral, matching Swap's current convention and error
  behavior.
- FR-004: Insufficient wallet funds and no pure-ADA collateral/fuel
  candidates surface the same underlying selection failures as Swap:
  `WalletShortfall` and `WalletNoPureAda` rendered as stable re-rate
  rejection diagnostics.
- FR-005: `amaru-treasury-tx swap-rerate` exposes
  `--wallet-address BECH32` for the normal live operator path. The
  manual `--wallet-txin` / `--collateral-txin` flags are removed from
  visible help and from the generated UI command.
- FR-006: Offline fixture execution may keep an explicit funding escape
  hatch if it is hidden/internal and required to preserve `just smoke`.
- FR-007: `POST /v1/build/swap-rerate` accepts a wallet address in the
  request JSON and delegates to the same CLI runner path.
- FR-008: The Operate UI Funding section for Re-rate is one wallet
  address field using the same address book/dropdown component as Swap.
- FR-009: CLI, HTTP, and UI requests with the same scope, selected
  orders, new rate, and wallet address route to the same runner fields
  and produce byte-identical unsigned transactions.
- FR-010: The UI slice includes a Playwright render test and a committed
  screenshot under `frontend/test/ui-review/419/`.

## Acceptance Criteria

- The visible CLI contract contains `--wallet-address` and does not ask
  for manual wallet/collateral tx-ins.
- The HTTP request type and PureScript request JSON use
  `srrWalletAddress` / `walletAddress`.
- The re-rate Operate page renders a single wallet-address Funding
  field and the build request contains the address.
- Existing offline re-rate fixtures and smoke checks remain green.
- `./gate.sh` passes at HEAD, including Haskell `just ci`, frontend
  build, re-rate Playwright render, and #419 screenshot assertion.

## Non-Goals

- Do not change the Swap path.
- Do not change the coin-selection engine internals.
- Do not change the presign-ladder explicit-UTxO batch model.
- Do not add market-rate automation or cross-scope re-rate behavior.
