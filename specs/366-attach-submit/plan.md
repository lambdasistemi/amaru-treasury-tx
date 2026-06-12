# Implementation Plan: Stateless Attach And Submit Endpoints

## Context

Issue #366 depends on #365, which added `/v1/tx/introspect`,
`/v1/verify-witness`, and the complete `ServerSpec` `Handlers` stub.
Current `main` already has a `POST /v1/submit` route, but it directly
calls `submitSignedTx` and returns a 200 status envelope. This ticket
must replace that with the stricter #366 contract: decode, treasury
shape preflight, Phase-1 preflight, then broadcast, with 4xx failures
before broadcast.

The implementation must reuse:

- `Amaru.Treasury.Tx.AttachWitness` for witness decoding and merge.
- `Amaru.Treasury.Tx.Submit` for the actual N2C LocalTxSubmission
  broadcast.
- `Amaru.Treasury.Build.Common.validateFinalPhase1` for structural
  Phase-1 validation.
- `Amaru.Treasury.Indexer.Decoder` classification helpers for
  treasury transaction shape.

## Owned Files

Implementation slices may touch only these surfaces unless the pair
writes a Q-file and receives an answer:

- `lib/Amaru/Treasury/Api/Server.hs`
- `lib/Amaru/Treasury/Api/Types.hs`
- `lib/Amaru/Treasury/Api/Attach.hs` (new)
- `lib/Amaru/Treasury/Api/Submit.hs` (new)
- `lib/Amaru/Treasury/Api/RateLimit.hs` (new, if needed)
- `app/amaru-treasury-tx-api/Main.hs`
- `test/unit/Amaru/Treasury/Api/ServerSpec.hs`
- `test/unit/Amaru/Treasury/Api/AttachSpec.hs` (new, if useful)
- `test/unit/Amaru/Treasury/Api/SubmitSpec.hs` (new, if useful)
- `test/fixtures/366-attach-submit/**` (new, if fixture files are
  preferable to reusing existing witness fixtures)
- `amaru-treasury-tx.cabal`

Forbidden: `frontend/`, `transactions/`, child #365 behavior, unrelated
specs, Nix/dependency pins, and production transaction archives.

## Wire Shape

Proposed attach request:

```json
{
  "unsignedTx": "<cbor-hex>",
  "witnesses": ["<witness-cbor-hex>"]
}
```

Proposed attach response:

```json
{
  "cborHex": "<signed-conway-tx-cbor-hex>"
}
```

Submit request keeps the existing field:

```json
{
  "cborHex": "<signed-conway-tx-cbor-hex>"
}
```

Submit success response:

```json
{
  "txid": "<64 lowercase hex chars>"
}
```

Failures use the existing `ApiError` JSON body and HTTP 4xx status.

## Slice Breakdown

### Slice 1 - Attach Endpoint

Add API carriers, pure attach helper, route, strict `hAttach` field,
and tests. The helper should be pure over request bytes, should reuse
`decodeUnsignedTxHex`, `decodeVKeyWitnessHex`, `attachWitnesses`, and
`encodeSignedTxHex`, and should map failures to `ApiError`.

TDD proof:

- RED: HTTP/helper tests for raw witness and envelope witness inputs,
  known signed CBOR fixture, malformed input, empty witness list, and
  body txid preservation using `/v1/tx/introspect` logic or equivalent
  txid extraction.
- GREEN: minimal helper and route wiring.

Commit subject:

`feat(api): add stateless attach endpoint`

Focused command:

`nix develop --quiet -c just unit "Attach"`

### Slice 2 - Submit Preflight And Broadcast Injection

Replace direct submit handling with an API submit helper that accepts a
broadcast dependency. The helper decodes the signed tx, classifies it
as treasury, gathers the input/reference/collateral UTxOs needed for
Phase-1 validation, runs `validateFinalPhase1`, and only then calls the
broadcast dependency backed by `submitSignedTx` in the binary.

TDD proof:

- RED: helper/server tests where non-treasury CBOR returns 4xx and a
  mocked submitter call count remains zero.
- RED: Phase-1 structural failure returns 4xx and the submitter call
  count remains zero. A frozen fixture or deliberately incomplete UTxO
  context is acceptable if it proves the no-broadcast boundary.
- RED: accepted mocked submit returns only `{ "txid": ... }`.
- GREEN: implement preflight, route error mapping, and binary wiring.

Commit subject:

`feat(api): preflight and submit treasury transactions`

Focused command:

`nix develop --quiet -c just unit "Submit"`

### Slice 3 - Shared Build/Submit Rate Limit

If no existing limiter exists, add a small API-owned limiter and apply
the same semantics to every `/v1/build/*` endpoint and `/v1/submit`.
The preferred behavior is a bounded single-flight or token limiter that
returns HTTP 429 with `ApiError` when saturated, without starting the
underlying build or submit action.

TDD proof:

- RED: build endpoint saturation returns 429 and does not execute the
  second build action.
- RED: submit endpoint uses the same limiter and returns the same 429
  shape without executing preflight or broadcast.
- GREEN: shared limiter module plus `Server.hs`/binary wiring.

Commit subject:

`feat(api): share rate limit for build and submit`

Focused command:

`nix develop --quiet -c just unit "Server"`

## Verification Strategy

Every slice must run:

- its focused `nix develop --quiet -c just unit "<pattern>"` command,
- `./gate.sh`.

The ticket owner reruns `./gate.sh` before accepting each slice and
logs `GATE-PASS` or `GATE-FAIL`.

The local `gate.sh` intentionally skips only
`Amaru.Treasury.Api.Ttl` and `Amaru.Treasury.Api.Proofs` in the unit
suite because this dev shell lacks `cq-rdf` and Apache Jena. CI's
hermetic Build Gate still covers those tests.

## Risks

- Phase-1 validation needs the correct input set. The submit helper
  should gather spend inputs, reference inputs, and collateral inputs
  from the decoded transaction body before sampling a `ChainContext`.
- Treasury classification must use deployment metadata mappings, not
  only static mainnet registry policies, so devnet and fixture tests can
  classify correctly.
- The existing `SubmitResponse` wire shape is looser than #366. Tests
  should lock the new `{ "txid": ... }` shape.
- Rate-limit semantics are not currently obvious in the codebase. If a
  hidden existing limiter is discovered, reuse it; otherwise implement a
  small shared helper and document the chosen 429 behavior in tests.

