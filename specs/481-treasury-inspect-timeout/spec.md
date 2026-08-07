# spec — #481 Bound `/v1/treasury-inspect` against a hung node query

Issue: https://github.com/lambdasistemi/amaru-treasury-tx/issues/481

## Problem

The web UI treasury inspector panes on `amaru-treasury.plutimus.com` show
"request timed out — the chain query is slow right now" because
`GET /v1/treasury-inspect` hangs forever (reproduced: 30s client timeout,
0 bytes back, on both the production 0.2.21.0 deployment and the dev
deployment).

Root cause, established live against production: `TreasuryInspect.nowTip`
calls the live `Provider`'s `posixMsToSlot` (N2C LocalStateQuery) to
compute `chain_tip`; that call never returns. Server trace logs confirm
it — every `provider.posixMsToSlot start` line (57 in a 2h window) is
never followed by an `ok after`/`error after` completion — while the
indexer's own chain-sync tip tracking stays healthy throughout
(`upstream tip slot=` keeps advancing). This reproduces even though
`cardano-node-clients` is already pinned past merged PR #185's "propagate
connection loss to pending LocalStateQuery callers" fix — the connection
here is not lost (chain-sync keeps advancing), so that fix's precondition
never fires; something else jams the shared N2C session and every
subsequent `posixMsToSlot` caller queues behind it forever.

The exact N2C-side defect is **out of scope for this slice** — it needs
its own investigation in `cardano-node-clients`. This slice makes the
symptom stop being a production incident: bound the wait and fail fast
and clearly instead of hanging the HTTP response forever.

## P1 user story

As an operator looking at a treasury pane, when the node's tip lookup is
stuck, I see a fast, clear "unavailable" response instead of an endless
spinner, within seconds — not held hostage by one broken metadata field
for an unbounded time.

## Invariants

- **INV-1** `GET /v1/treasury-inspect?scope=<valid>` fully sends its HTTP
  response within `nowTipTimeoutSeconds` (10s) of receipt, in every case
  — including one where the live `Provider`'s `posixMsToSlot` never
  returns. "Responds" means the client actually receives a complete
  response, not that some background computation merely gives up.
- **INV-2** On a `nowTip` timeout, the API responds `503 Service
  Unavailable` with an `ApiError` JSON body matching the existing
  `err429`/`err400` shape already used in `Api/Server.hs` (`submitH`),
  explaining that the chain-tip query timed out. It must not surface as
  Warp's generic unlabeled `500`.
- **INV-3** `treasury-inspect` (CLI) surfaces the same timeout as a
  distinguishable `node: ...` stderr message and exits `3`, via its
  existing `try @SomeException` wrapper in `runTreasuryInspect` — no new
  CLI-side branch should be needed if the timeout is thrown as an
  exception from `nowTip` itself.
- **INV-4** A live node that answers promptly is unaffected: happy-path
  behavior and latency do not change.

## Non-goals

- Fixing the actual N2C/LocalStateQuery deadlock in
  `cardano-node-clients` — file a companion upstream issue there; do not
  chase it in this repo.
- Making `chain_tip` degrade gracefully inside a still-`200` report
  (indexer-backed treasury/swap-order data is unaffected by the stuck
  node call and could in principle still be served) — worth a follow-up
  ticket; this slice fails the whole request fast instead.
- A configurable timeout (CLI flag / env var / metadata knob) — a single
  hardcoded named constant is enough for this hotfix.

## Acceptance evidence

- A unit (Hspec) test that supplies a `Provider IO` whose `posixMsToSlot`
  blocks forever and asserts the request-handling path returns within a
  bounded margin with the `503`/`ApiError` shape from INV-2. The test
  itself must be wall-clock bounded (e.g. via `System.Timeout.timeout`)
  so a regression fails the test suite fast rather than hanging CI.
- A test (or, if the CLI entry point resists direct unit testing,
  a documented manual reproduction) covering INV-3's `node: ...` / exit
  `3` behavior for the same stuck-provider input.
- `just ci` green.
