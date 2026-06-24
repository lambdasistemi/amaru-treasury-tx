# Issue 419 Plan

## Technical Shape

The work keeps re-rate on the existing `runSwapRerate` path so CLI,
HTTP, and UI stay byte-identical by construction. The core change is
the funding input shape:

- live/operator funding: wallet bech32 address,
- internal/offline compatibility: explicit tx-in funding only where
  fixtures need it,
- runner resolution: query wallet address UTxOs, convert them to the
  `(txInText, lovelace, hasNativeAssets)` shape, call
  `SwapWizard.selectWallet SwapWizard.walletFeeSlackLovelace`, parse
  the selected head tx-in, and use that same head as collateral.

The re-rate runner should not duplicate Swap's selection sort or
eligibility rules. It may add adapter helpers to turn ledger UTxOs into
`selectWallet` candidates.

## Slices

### Slice 1: Backend and CLI Funding Parity

Change `SwapRerateOpts` to carry a funding mode. The visible parser
accepts `--wallet-address`; the explicit tx-in mode is kept only as a
hidden/internal offline escape hatch. The live resolver queries the
wallet address and reuses `selectWallet`; offline fixture execution
continues to build from the committed swap fixture.

Focused proof: `just unit "Amaru.Treasury.Cli.SwapRerate"` and
`scripts/smoke/swap-rerate-offline`.

### Slice 2: HTTP Request Parity

Change `SwapRerateBuildRequest` from wallet/collateral tx-ins to a
wallet address. Update server tests and the API adapter so it passes
the wallet-address funding mode to `runSwapRerate`.

Focused proof: `just unit "Amaru.Treasury.Api.BuildSwapRerate"` and
`just unit "Amaru.Treasury.Api.Server"`.

### Slice 3: Operate UI Parity

Change the PureScript API type/request JSON and Operate page state so
Re-rate Funding uses the same wallet-address field as Swap. Remove the
two tx-in fields from validation, request JSON, generated CLI command,
and Playwright tests. Update the render test to assert the simplified
field and capture the #419 screenshot.

Focused proof: build `.#frontend` and run
`frontend/test/playwright/rerate-mode.spec.ts` against the built
frontend.

### Slice 4: Final Gate and PR Readiness

Run `./gate.sh`, audit task completion and commit messages, update the
PR body if the delivered behavior differs from the plan, then drop
`gate.sh` in the final ready-for-review commit.

## Risks

- The repo's commit hook may hit the known transient
  `cuddle-1.1.1.0` SRP fetch. Remove partial
  `dist-newstyle/src/cuddle*` and retry before using `--no-verify`.
- `just ci` is Haskell-only for frontend rendering, so the PR-local
  `gate.sh` includes the frontend build and Playwright render proof.
- Scripts under `scripts/smoke/` are touched only when required to keep
  the existing smoke gate aligned with the new CLI contract.
