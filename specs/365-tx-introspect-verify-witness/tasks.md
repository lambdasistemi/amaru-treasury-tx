# Tasks — #365 stateless tx-introspect + verify-witness

One bisect-safe commit per slice. Each commit body carries
`Tasks: T###[, T###]`. Boxes flip to `[X]` in the same amended slice commit on
acceptance.

## Slice S1 — `POST /v1/tx/introspect`

- [X] T101 RED: `test/unit/Amaru/Treasury/Api/IntrospectSpec.hs` asserting,
  against `test/fixtures/118-vault-witness/`:
  (a) `introspectTx Nothing (IntrospectRequest <unsigned.cbor.hex>)` returns
  `Right` with the fixture txid, `requiredSigners == [<key.hash>]`,
  `invalidHereafter == Just <fixture TTL>` (or `Nothing` — read the actual
  fixture), and `scope == Nothing`;
  (b) garbage hex returns `Left ApiError` (SC-002, FR-002).
- [X] T102 GREEN: `lib/Amaru/Treasury/Api/Introspect.hs` exporting
  `introspectTx :: Maybe TreasuryMetadata -> IntrospectRequest -> Either
  ApiError IntrospectResponse`, reusing `decodeWitnessTransaction`,
  `witnessTransactionFacts`, `renderGuardKeyHash`, `txIdText`, and `vldtTxBodyL`
  for the TTL. `scope` best-effort (`Nothing` with `Nothing` metadata).
- [X] T103 `IntrospectRequest` + `IntrospectResponse` carriers in
  `Api/Types.hs` with explicit `ToJSON`/`FromJSON` per the wire shape in
  plan.md; export them.
- [X] T104 Route `"tx" :> "introspect" :> ReqBody :> Post` in `JsonAPI`, the
  pure `hIntrospect :: IntrospectRequest -> Either ApiError IntrospectResponse`
  field on `Handlers`, and `mkServer` wiring that maps `Left` to `err400` with
  the `ApiError` JSON body (FR-002).
- [X] T105 Binary wiring in `app/amaru-treasury-tx-api/Main.hs`:
  `hIntrospect = introspectTx <serverMetadata>`.
- [X] T106 `.cabal`: expose `Amaru.Treasury.Api.Introspect` (library) and add
  `Amaru.Treasury.Api.IntrospectSpec` to `unit-tests` other-modules.
- [X] T107 `./gate.sh` green; one commit
  `feat(365): stateless POST /v1/tx/introspect endpoint`.

## Slice S2 — `POST /v1/verify-witness`

- [ ] T201 RED: `test/unit/Amaru/Treasury/Api/VerifyWitnessSpec.hs` asserting,
  against `test/fixtures/118-vault-witness/` (+ `106-cardano-cli-oracle` tx
  body, + the wrong-key vault identity via `createWitness`):
  (a) matching `witness.expected.hex` over `unsigned.cbor.hex` →
  `VerifyWitnessResponse { ok = True, signerKeyHash = Just <key.hash> }`
  (SC-003);
  (b) wrong-key witness over the same tx → `ok = False`, reason names the
  required-set mismatch;
  (c) a witness whose vkey **is** required but signs the `106` body →
  `ok = False`, signature does not verify;
  (d) malformed witness hex (`"deadbeef"`) → `ok = False`, malformed
  (SC-004).
- [ ] T202 GREEN: `lib/Amaru/Treasury/Api/VerifyWitness.hs` exporting
  `verifyWitness :: VerifyWitnessRequest -> VerifyWitnessResponse` (total,
  pure), reusing `decodeWitnessTransaction`, `witnessTransactionFacts` (for the
  required-signer set + body hash), `decodeVKeyWitnessHex`, `verifySignedDSIGN`,
  `hashKey`, and `renderGuardKeyHash`.
- [ ] T203 `VerifyWitnessRequest` + `VerifyWitnessResponse` carriers in
  `Api/Types.hs` with explicit `ToJSON`/`FromJSON` per plan.md; export them.
- [ ] T204 Route `"verify-witness" :> ReqBody :> Post` in `JsonAPI`, the pure
  `hVerifyWitness :: VerifyWitnessRequest -> VerifyWitnessResponse` field on
  `Handlers`, and `mkServer` wiring (`pure . hVerifyWitness`).
- [ ] T205 Binary wiring in `app/amaru-treasury-tx-api/Main.hs`:
  `hVerifyWitness = verifyWitness`.
- [ ] T206 `.cabal`: expose `Amaru.Treasury.Api.VerifyWitness` (library) and
  add `Amaru.Treasury.Api.VerifyWitnessSpec` to `unit-tests` other-modules.
- [ ] T207 Statelessness assertion comment + test note that `verifyWitness` /
  `introspectTx` are pure (no `IO`, no store) — the type is the SC-005 proof.
- [ ] T208 `./gate.sh` green; one commit
  `feat(365): stateless POST /v1/verify-witness endpoint`.

## Orchestrator-owned finalization

- [ ] T300 PR body audit; `chore: drop gate.sh (ready for review)`; `gh pr
  ready 371`.
