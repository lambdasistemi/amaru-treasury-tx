# Spec — #365 Server: stateless tx-introspect + verify-witness endpoints

Issue: lambdasistemi/amaru-treasury-tx#365 · Parent epic: #370
(browser-local co-signing workbench). First child; #366 (attach+submit)
depends on the route-table + `Api/Types` shape established here.

## P1 user story

As an operator's browser client, I `POST` an unsigned tx and get back
`{ txid, requiredSigners, invalidHereafter }`, and I `POST` `{ unsigned tx,
detached witness }` and observe whether it is a valid witness and which
required signer it satisfies — **without any client-side ledger code**. The
server does all CBOR/crypto; the browser holds only opaque hex + the metadata
these endpoints return.

## Functional requirements

- **FR-001** `POST /v1/tx/introspect` accepts `{ cborHex }` (opaque unsigned
  Conway tx hex; a `cardano-cli` Conway tx-body envelope is also accepted) and
  returns `{ txid, requiredSigners: [keyHash], invalidHereafter, scope }`.
  - `txid` — lowercase hex transaction id of the decoded body.
  - `requiredSigners` — lowercase-hex key hashes from the body's
    required-signer set, ascending order, possibly empty.
  - `invalidHereafter` — the body's TTL slot as a number, or `null` when the
    body declares no upper validity bound.
  - `scope` — best-effort treasury scope name resolved purely from the
    decoded body + verified metadata; `null` when not resolvable (no metadata,
    or no unambiguous match). This is the optional `scope?` field.
- **FR-002** introspect **fails closed** with a 4xx (`400`) and a JSON
  `ApiError` body on input that is not a decodable Conway tx body. No 5xx, no
  partial result.
- **FR-003** `POST /v1/verify-witness` accepts `{ unsignedTx, witness }` (both
  opaque hex; `witness` is a detached vkey witness — bare ledger `WitVKey` or
  the `cardano-cli` `[0, WitVKey]` envelope) and returns
  `{ ok: true, signerKeyHash }` **iff** the witness signature is valid over the
  unsigned tx's body hash **and** the witness vkey hashes into the tx's
  required-signer set.
- **FR-004** verify-witness returns `{ ok: false, reason }` (HTTP 200, total —
  never 4xx/5xx for a verification outcome) for each negative case:
  - the signature does not verify over the body hash,
  - the vkey is valid and verifies but is **not** in the required-signer set,
  - the witness hex is malformed / not a vkey witness,
  - the unsigned tx hex is not a decodable Conway tx body.
- **FR-005** Both endpoints persist **nothing**. They are pure compute: input
  in, result out, no store handle on the handler path.

## Architectural invariants (from parent epic #370)

- New server endpoints are **stateless compute only** — nothing stored.
- Signing keys never reach browser or server; only detached `[vkey, sig]`
  witnesses are handled.
- The browser holds only opaque tx/witness hex + server-returned metadata — no
  client-side ledger / CBOR / crypto.

## Success criteria

- **SC-001** A real treasury-tx body fixture with a non-empty required-signer
  set and a TTL introspects to its exact txid, its required-signer hash set,
  and its TTL slot. (fixture: `test/fixtures/118-vault-witness/`)
- **SC-002** Garbage / non-Conway-tx input to introspect yields a 4xx with an
  `ApiError` body, not a 5xx or a 200.
- **SC-003** The fixture's matching detached witness
  (`witness.expected.hex`) verifies against `unsigned.cbor.hex`:
  `{ ok: true, signerKeyHash = <fixture key.hash> }`.
- **SC-004** Three negatives all yield `{ ok: false, reason }`:
  (a) a valid witness by a key **not** required (wrong-key vault identity over
  the same tx); (b) a witness whose vkey **is** required but signs a different
  body (signature does not verify); (c) malformed witness hex.
- **SC-005** Statelessness is enforced **by construction**: both handlers are
  total pure functions in the `Handlers` record (`IntrospectRequest ->
  Either ApiError IntrospectResponse` and `VerifyWitnessRequest ->
  VerifyWitnessResponse`) — no `IO`, no provider, no store. A unit test drives
  the pure core directly; the type is the proof of no store write.

## Non-goals

- Attaching witnesses or submitting (child #366) — but this ticket sets the
  `v1/tx/*` route-table and `Api/Types` request/response shape #366 will
  extend.
- Any server-side storage of txs or witnesses.
- Client UI (children C–E of #370).

## Out of scope / forbidden

- attach/submit endpoints, any `frontend/`, other children's specs, epic /
  parent issue metadata.
