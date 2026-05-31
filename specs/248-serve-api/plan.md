# Implementation Plan: Indexer-Backed Serve API

## Scope

Extend the existing `amaru-treasury-tx-api` executable and Servant
surface. The current issue comment confirms that history and build
routes are already shipped on `main`; this plan covers the missing read
routes and node-touching utility routes.

## Slices

1. **Transaction Detail**
   Add `GET /v1/tx/{txid}`. Reuse
   `Amaru.Treasury.Cli.History.queryTxDetail` and
   `renderTxDetail`, with a structured JSON response and `404` for
   missing indexed transactions.

2. **State Reads**
   Add scope state, UTxO, pending order, registry, and scripts routes.
   State and pending data come from the embedded indexer-backed
   provider; registry/scripts come from loaded metadata.

3. **Node Utility Routes and Health**
   Add tip, params, submit, and health routes. Tip/params/submit are the
   only new routes allowed to use the node. Health uses the readiness
   bridge already consumed by `withLagGuard`.

4. **Config Surface Follow-Up**
   The live issue still lists `amaru-treasury-tx serve --config`; the
   re-scope comment also notes the standalone `-api` executable as the
   current reality. If the parent confirms the subcommand is required in
   this PR, wire it as a thin delegating CLI surface after the endpoints
   are complete.

## Verification

- Focused unit tests after each slice.
- `just build` and `just unit` before gate pass.
- `nix build .#checks.x86_64-linux.unit` when the Nix shell/build cache
  is available.
- Devnet smoke is live-boundary and may be logged as a follow-up if the
  node/devnet environment is unavailable.
