# Feature Specification: Stateless Attach And Submit Endpoints

**Issue**: #366  
**Parent**: #370  
**PR**: #374  
**Status**: Draft implementation plan

## Goal

Add two stateless HTTP endpoints to `amaru-treasury-tx-api` so the
browser client can assemble a signed transaction from collected
detached witnesses, then submit the fully signed treasury transaction
to the local node.

## P1 User Story

As an operator's browser client, I POST an unsigned transaction plus
its collected witnesses and receive signed transaction CBOR hex; then I
POST that signed transaction and receive the submitted transaction id
after the server validates it is a treasury transaction and Phase-1
valid.

## Deliverables

- `POST /v1/attach` on the existing `amaru-treasury-tx-api` HTTP
  surface.
- `POST /v1/submit` on the existing `amaru-treasury-tx-api` HTTP
  surface, replacing the current status-envelope stub semantics with
  preflighted `{ "txid": ... }` success and 4xx preflight failures.
- API carrier types in `Amaru.Treasury.Api.Types` and handler wiring in
  `Amaru.Treasury.Api.Server`.
- API helper modules for attach, submit preflight, and shared
  rate-limiting if the implementation keeps those concerns outside
  `Server.hs`.
- Unit tests in the existing `unit-tests` suite; no frontend, docs site,
  transaction archive, or new executable is shipped by this ticket.

The release artifact is the existing `amaru-treasury-tx-api` binary and
container package. This ticket changes its runtime HTTP surface only.

## Functional Requirements

- **FR-001**: `POST /v1/attach` MUST accept JSON containing an unsigned
  transaction CBOR hex string and one or more detached witness CBOR hex
  strings.
- **FR-002**: `POST /v1/attach` MUST accept both raw ledger
  `[vkey, sig]` witnesses and cardano-cli `[0, [vkey, sig]]` envelope
  witnesses by reusing `Amaru.Treasury.Tx.AttachWitness`.
- **FR-003**: `POST /v1/attach` MUST return signed transaction CBOR hex
  and MUST preserve the transaction body bytes: the txid computed from
  the signed transaction body equals the txid computed from the unsigned
  transaction body.
- **FR-004**: `POST /v1/attach` MUST be stateless and MUST not read or
  write the API indexer, history store, transaction archive, or any
  other server-side persistence.
- **FR-005**: `POST /v1/submit` MUST decode the supplied signed Conway
  transaction before any broadcast.
- **FR-006**: `POST /v1/submit` MUST reject a transaction that does not
  classify as an Amaru treasury transaction before broadcast.
- **FR-007**: `POST /v1/submit` MUST run Phase-1 validation against a
  live provider snapshot before broadcast and reject structural
  failures before broadcast.
- **FR-008**: `POST /v1/submit` MUST broadcast only after FR-005 through
  FR-007 pass, using the existing
  `Amaru.Treasury.Tx.Submit.submitSignedTx` N2C LocalTxSubmission path.
- **FR-009**: A successful submit response MUST be a JSON object with a
  `txid` field containing the lowercase 64-character transaction id.
- **FR-010**: Preflight submit failures MUST be HTTP 4xx responses with
  the existing structured `ApiError` body and MUST not call the
  broadcast dependency.
- **FR-011**: Submit MUST be rate-limited consistently with `/v1/build`.
  If the implementation adds a new limiter, build endpoints and submit
  must use the same limiter semantics.
- **FR-012**: `Handlers` stubs in `ServerSpec` MUST remain complete, and
  the new or changed `Handlers` fields for attach and submit MUST be
  strict.

## Non-Goals

- No server-side storage of witnesses, signed transactions, or submit
  attempts.
- No changes to the frontend.
- No changes to child #365 endpoints (`/v1/tx/introspect` and
  `/v1/verify-witness`) except using them as test oracles.
- No transaction archive ceremony under `transactions/`.
- No production mainnet submission during this ticket's local tests.

## Acceptance Criteria

- `POST /v1/attach` merges detached witnesses and returns signed CBOR
  hex.
- Attach accepts raw and cardano-cli envelope witness forms.
- Attach preserves the body txid across unsigned and signed
  transaction bytes.
- `POST /v1/submit` rejects non-treasury or Phase-1-invalid
  transactions with 4xx and without broadcast.
- `POST /v1/submit` broadcasts a valid signed treasury transaction over
  the reusable N2C submit path and returns `{ "txid": ... }`.
- Submit is rate-limited consistently with `/v1/build`.
- Both endpoints persist nothing.
- Tests cover attach round-trip against a known fixture and submit
  success/rejection via a mocked submission client or devnet-backed
  proof.

## Edge Cases

- Malformed transaction hex returns 4xx, not a 200 status envelope.
- Malformed witness hex returns 4xx from attach.
- Empty witness list is rejected by attach.
- Duplicate witnesses are tolerated by the existing set-union semantics.
- A tx that decodes as Conway but carries no recognized treasury signal
  is rejected by submit before broadcast.
- A tx whose Phase-1 failures are structural is rejected before
  broadcast.
- A node rejection after preflight is surfaced as an error response, but
  the no-broadcast guarantee applies specifically to preflight rejects.

