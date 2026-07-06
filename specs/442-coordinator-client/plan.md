# Implementation Plan: Coordinator Client

## Constraints

- Branch: `feat/coordinator-client` in
  `/code/amaru-treasury-tx-442`.
- Gate: `nix develop --accept-flake-config -c just ci`.
- Commit with `git commit --no-verify`; do not repin
  `cabal.project`.
- Client only. No full devnet e2e and no coordinator repo edits.
- Reuse existing signing and assembly helpers:
  `Amaru.Treasury.Tx.Witness.createWitness`,
  `decodeWitnessTransaction`, `witnessTransactionFacts`,
  `Amaru.Treasury.Tx.AttachWitness.attachWitnesses`,
  `decodeUnsignedTxHex`, `decodeVKeyWitnessHex`, and
  `encodeSignedTxHex`.

## Design

Add a small coordinator namespace under
`lib/Amaru/Treasury/Coordinator/`:

- `Client`: OpenAPI-shaped request/response types, error rendering,
  URL construction, and HTTP actions for `/v1/fee-quote`,
  `/v1/fee-status/{id}`, `/v1/entries`,
  `/v1/entries/{id}/witnesses`, and
  `/v1/entries/{id}/submit`.
- `Workflow`: ordered coordination flow over injected effects:
  quote, local body-hash check, requester pre-witness, fee payment,
  status polling, publish, owner witness upload, submit. Tests can
  inject a stub coordinator and a stub fee payer.
- `FeePayment`: node-backed helper for the CLI that pays the quoted fee
  from a requester wallet and tags metadata label `9721` with
  `body_hash`. Keep this as a small boundary so the workflow remains
  unit-testable without a node.

Add `lib/Amaru/Treasury/Cli/Coordinate.hs` for parser and runner, wire
it into `Amaru.Treasury.Cli` and `app/amaru-treasury-tx/Main.hs`.

The standalone `witness` command's guard should remain unchanged: it is
correct to reject non-required keys when required signers are declared.
The coordinator workflow has a narrower requester pre-witness case and
should call `createWitness` directly after resolving the requester
vault identity and network.

## Test Strategy

- Focused RED/GREEN tests in `test/unit`.
- Use fixture transaction/witness data under
  `test/fixtures/118-vault-witness` where possible.
- Use stubbed coordinator responses or a WAI/Warp local application for
  the `/v1` component path; do not require a live coordinator or devnet.
- Parser tests assert the public CLI shape without performing network
  or node IO.

## Slices

### Slice 1: Wire Client

Introduce the OpenAPI-shaped client module and tests for JSON field
names, URL construction, error decoding, and basic HTTP method/path
selection through an injected transport.

### Slice 2: Coordination Workflow

Introduce the pure/effect-injected workflow. Prove body-hash mismatch
short-circuits, requester pre-witness preserves the body hash, owner
witness upload follows publish, and submit returns the receipt from a
stub coordinator.

### Slice 3: CLI And Fee Payment

Wire `coordinate` into the shipped executable. Add the node-backed fee
payment boundary, vault option parsing, CLI help/parser tests, and a
stubbed runner test that proves CLI options map to the workflow.

## Finalization

After all slices pass:

1. Run `nix develop --accept-flake-config -c just ci`.
2. Push the branch and keep the PR body updated with `Closes #442`.
3. Drop `gate.sh` if any slice created one.
4. Mark the PR ready for review.
5. Wait until the GitHub Actions `CI` workflow is green; ignore
   `Build and deploy documentation`.
6. Do not merge.
