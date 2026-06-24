# Issue 419 Tasks

## Slice 1: Backend and CLI Funding Parity

- [ ] T419-S1 Update `SwapRerateOpts` and parser so visible CLI funding
  is `--wallet-address` and explicit tx-in funding is hidden/internal.
- [ ] T419-S1 Reuse `SwapWizard.selectWallet` in live re-rate funding
  resolution and map wallet selection failures to stable re-rate
  rejections.
- [ ] T419-S1 Update CLI unit tests and offline smoke script for the new
  contract while preserving fixture execution.
- [ ] T419-S1 Run focused CLI proof and commit.

## Slice 2: HTTP Request Parity

- [ ] T419-S2 Change `SwapRerateBuildRequest` and API adapter to accept
  wallet address instead of wallet/collateral tx-ins.
- [ ] T419-S2 Update server/API unit tests for the new JSON shape.
- [ ] T419-S2 Run focused API proof and commit.

## Slice 3: Operate UI Parity

- [ ] T419-S3 Change PureScript request type/JSON to send wallet
  address.
- [ ] T419-S3 Replace Re-rate Funding with the shared wallet-address
  field and remove tx-in validation/state/CLI rendering.
- [ ] T419-S3 Update Playwright coverage and commit
  `frontend/test/ui-review/419/419-rerate-operate-desktop-1280.png`.
- [ ] T419-S3 Run frontend build plus re-rate Playwright proof and
  commit.

## Slice 4: Final Gate and PR Readiness

- [ ] T419-S4 Run `./gate.sh` at HEAD and record the evidence.
- [ ] T419-S4 Audit PR body and task accounting.
- [ ] T419-S4 Drop `gate.sh`, push, and mark PR ready for review.
