# plan — #481 Bound `/v1/treasury-inspect` against a hung node query

## Architecture

- `lib/Amaru/Treasury/Cli/Common.hs::nowTip` (currently line 364) — wrap
  the existing `posixMsToSlot p nowMs` call in
  `System.Timeout.timeout nowTipTimeoutMicros`. On `Nothing`, throw a
  new, specific, catchable exception rather than changing `nowTip`'s
  return type to `Either`/`Maybe` — this keeps both existing call sites
  (`TreasuryInspect.hs:223`, `TreasuryInspect.hs:266`) and
  `SwapRerate.hs:723` source-compatible with zero ripple. Export the
  exception type and the timeout constant next to `nowTip`.
- `lib/Amaru/Treasury/Api/Server.hs::inspectH` (currently
  `inspectH scope = liftIO (hInspectReport scope)`) — this is the one
  Server.hs call site that needs new exception handling: catch the new
  timeout exception around the `hInspectReport scope` call and convert
  it to `err503` via the same `throwApiError`-style pattern already used
  by `submitH` for `err429`/`err400` (see lines ~656–671). `hInspectReport`
  keeps its existing type `ScopeId -> IO InspectReport` — the catch lives
  at the `Handler` boundary, not inside the report builder.

## Modules touched

- `Amaru.Treasury.Cli.Common` — new exported exception type + a
  `nowTip` that can now fail instead of only hanging.
- `Amaru.Treasury.Api.Server` — new `catch` at `inspectH`.
- No changes to `TreasuryInspect.hs`, `SwapRerate.hs`, or any data type
  (`InspectReport`, `ChainTip`, `ApiError`, …). This is a pure
  boundary-hardening slice; every existing caller of `nowTip` keeps
  compiling unchanged (they already run inside exception-aware contexts:
  `try @SomeException` in the CLI, ordinary IO in `SwapRerate.hs`).

## Functions (new/changed only)

- `nowTip :: Provider IO -> IO Word64` — signature unchanged; behavior
  gains a bounded wait and a new failure mode (throws instead of hanging
  past the bound).
- A new exception type, e.g. `newtype NowTipTimeout = NowTipTimeout Int`
  (seconds) with `deriving Show` and `instance Exception NowTipTimeout`
  — exact naming/shape is the commit owner's call.
- `nowTipTimeoutSeconds :: Int` — named constant, value `10`. Placed
  next to `nowTip` with a haddock explaining why (references this
  ticket).

## Out of scope / explicitly forbidden

- Do not touch `posixMsToSlot`'s implementation in `cardano-node-clients`
  (`source-repository-package`, separate repo/ticket).
- Do not change `InspectReport` / `ChainTip` / `ApiError` shape.
- Do not add a CLI flag, env var, or metadata knob for the timeout value
  in this slice.
- Do not touch anything under `frontend/` — the fix is entirely
  server/CLI-side; the panes just need the hang gone.

## Verification commands

- `nix develop --quiet -c just unit`
- `nix develop --quiet -c just ci` *(full: build + schema-check + unit +
  golden + format-check + hlint + smoke + release-check)*
- Do not point any test at the real production node/socket; the stuck
  provider must be an in-process test double.
