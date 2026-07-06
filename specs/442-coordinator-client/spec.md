# Feature Specification: Coordinator Client

## User Story

As an Amaru treasury operator, I want `amaru-treasury-tx` to drive a
`cardano-multisig` `/v1` coordinator for witness collection so the
manual `witness -> attach-witness -> submit` tail can be replaced by a
single audited client workflow.

## Scope

This ticket builds the client-side library and CLI surface only. It
does not run the full treasury/Sundae/coordinator devnet e2e; that is
#443. Tests for this ticket use pure unit tests and a stubbed or
recorded `/v1` coordinator flow.

The coordinator contract of record is
`/code/cardano-multisig/openapi/v1.yaml` on `main`:

1. `POST /v1/fee-quote {"transaction": <cborHex>}`.
2. Verify returned `body_hash` equals
   `extractHash (hashAnnotated body)` for the unsigned Conway body.
3. Pre-witness the requester fuel/collateral key using the existing
   vault/witness signing path, even though that key is not in
   `required_signers`.
4. Pay the coordinator fee to `fee_address` with metadata label `9721`
   carrying `{ "body_hash": <body_hash> }`.
5. Poll `GET /v1/fee-status/{body_hash}` until the fee is paid.
6. `POST /v1/entries {"transaction": <partiallyWitnessedTx>}`.
7. For each owner vault identity, create an existing raw `WitVKey`
   witness and `POST /v1/entries/{id}/witnesses`.
8. `POST /v1/entries/{id}/submit` and return the receipt.

## Functional Requirements

- FR-001: The client SHALL encode and decode the `/v1` request and
  response JSON shapes used by fee quote, fee status, publish, witness
  upload, and submit.
- FR-002: The client SHALL normalize the base URL so callers may pass
  either the service root or a `/v1` URL without double-prefixing.
- FR-003: The workflow SHALL compute the local unsigned transaction
  body hash and reject a fee quote whose `body_hash` differs.
- FR-004: The requester pre-witness SHALL reuse
  `Amaru.Treasury.Tx.Witness.createWitness` and
  `Amaru.Treasury.Tx.AttachWitness.attachWitnesses`; it SHALL NOT
  implement Ed25519 signing or transaction assembly independently.
- FR-005: Owner witnesses SHALL use the same vault-backed witness
  creation path and upload raw `WitVKey` CBOR hex to
  `/entries/{id}/witnesses`.
- FR-006: The fee payment SHALL pay the returned `fee_address` for
  `required_fee_lovelace` and include metadata label `9721` containing
  the returned body hash.
- FR-007: The workflow SHALL poll fee status with a bounded retry
  policy and surface coordinator errors as typed failures.
- FR-008: The CLI SHALL expose a `coordinate` command that accepts an
  unsigned transaction, coordinator URL, requester fee/fuel wallet
  inputs, requester vault identity, and one or more owner vault
  identities.
- FR-009: The command SHALL emit a machine-readable receipt or summary
  including the coordinator entry id, uploaded witness signer hashes,
  submitted tx id, fee payment reference when known, and final status.
- FR-010: The implementation SHALL NOT alter swap builder/on-chain
  logic, coordinator repository files, or dependency pins.

## Acceptance Criteria

- AC-001: Unit tests prove the JSON wire shapes match the OpenAPI field
  names and required fields.
- AC-002: A component test using a stub coordinator proves the ordered
  call sequence: quote, fee status, publish, witness upload for each
  owner, submit.
- AC-003: A unit test proves quote `body_hash` is checked against
  `hashAnnotated body` and mismatches abort before fee payment or
  publish.
- AC-004: A unit test proves requester pre-witnessing preserves the
  transaction body hash while adding an existing vkey witness.
- AC-005: CLI parser tests prove `coordinate --help` and required flags
  are wired.
- AC-006: Local verification uses
  `nix develop --accept-flake-config -c just ci`.
- AC-007: The final PR body contains `Closes #442`, the PR is ready for
  review, and the GitHub Actions `CI` workflow is green. The docs
  deploy workflow is not authoritative for this ticket.
