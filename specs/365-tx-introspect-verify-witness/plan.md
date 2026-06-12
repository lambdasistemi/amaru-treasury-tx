# Plan — #365 stateless tx-introspect + verify-witness

## Tech stack

- Haskell, GHC 9.12 via `nix develop`. Fourmolu 70-col, `-Werror`, Haddock on
  every export.
- `cardano-ledger-conway` (Conway body lenses), `cardano-crypto-class`
  (`verifySignedDSIGN`), `servant-server` (routes), `aeson` (wire shapes),
  Hspec (unit).

## Reuse map (do not reinvent)

The decode + facts + witness machinery already exists; both endpoints are thin
pure wrappers over it.

- `Amaru.Treasury.Tx.Witness.decodeWitnessTransaction :: ByteString -> Either
  TxWitnessError ConwayTx` — decodes raw CBOR hex **or** a `cardano-cli` Conway
  tx envelope.
- `Amaru.Treasury.Tx.Witness.witnessTransactionFacts :: ConwayTx ->
  TransactionSigningFacts` — yields `tsfRequiredSigners :: Set (KeyHash Guard)`
  and `tsfBodyHashHex`.
- `Amaru.Treasury.Tx.Witness.renderGuardKeyHash :: KeyHash Guard -> Text` —
  lowercase-hex key hash.
- `Amaru.Treasury.Tx.AttachWitness.decodeVKeyWitnessHex :: Int -> ByteString ->
  Either AttachError (WitVKey Witness)` — decodes a detached witness (bare or
  `[0, WitVKey]` envelope).
- `Amaru.Treasury.Build.Common.txIdText :: ConwayTx -> Text` — lowercase-hex
  txid.
- Conway body lens `vldtTxBodyL` → `Cardano.Ledger.Allegra.Scripts`
  `ValidityInterval { invalidHereafter :: StrictMaybe SlotNo }` for the TTL.
- `Cardano.Crypto.DSIGN.Class.verifySignedDSIGN`,
  `Cardano.Ledger.Keys` (`WitVKey (..)`, `VKey (..)`, `hashKey`),
  `Cardano.Ledger.Hashes` (`hashAnnotated`, `extractHash`) for the signature
  check and signer-key-hash derivation.
- `Amaru.Treasury.Api.Types.ApiError` — existing uniform 4xx body.

## Statelessness design (the proof)

Both handlers are **pure fields** in the `Handlers` record, so "no store
write" is a type-level guarantee, not a runtime assertion:

```haskell
hIntrospect     :: IntrospectRequest -> Either ApiError IntrospectResponse
hVerifyWitness  :: VerifyWitnessRequest -> VerifyWitnessResponse
```

`mkServer` maps them: introspect threads `Left -> err400 { errBody = encode
apiError }`; verify-witness is total (`pure . hVerifyWitness`). The binary
closes `hIntrospect = introspectTx metadata` over the server's verified
`Maybe TreasuryMetadata`; tests pass `Nothing` (scope → `null`).

## Route table (sets the pattern #366 extends)

Add to `JsonAPI` in `Server.hs`, grouped under the existing `"v1"` block.
Place the **static** `"tx" :> "introspect"` POST route adjacent to the
existing `"tx" :> Capture "txid"` GET; static segments and the distinct method
keep precedence unambiguous, but keep introspect listed before the capture for
clarity.

```
"tx" :> "introspect" :> ReqBody '[JSON] IntrospectRequest
     :> Post '[JSON] IntrospectResponse
"verify-witness"     :> ReqBody '[JSON] VerifyWitnessRequest
     :> Post '[JSON] VerifyWitnessResponse
```

`#366` (attach/submit) extends the same `v1/tx/*` family: attach is another
**pure** `Handlers` field; submit reuses the existing IO `hSubmit` shape. Keep
the request/response carriers in `Api/Types.hs` with explicit `ToJSON`/
`FromJSON` (matching the file's convention) so the wire contract is decoupled
from record prefixes.

## Wire shapes (`Api/Types.hs`)

```jsonc
// IntrospectRequest
{ "cborHex": "<hex>" }
// IntrospectResponse
{ "txid": "<hex>", "requiredSigners": ["<keyHash>", ...],
  "invalidHereafter": <number|null>, "scope": "<name>|null" }

// VerifyWitnessRequest
{ "unsignedTx": "<hex>", "witness": "<hex>" }
// VerifyWitnessResponse (ok)        { "ok": true,  "signerKeyHash": "<hex>" }
// VerifyWitnessResponse (not ok)    { "ok": false, "reason": "<text>" }
```
`signerKeyHash`/`reason` are nullable and mutually exclusive; emit both keys
(one `null`) for a stable shape.

## Slice breakdown (one bisect-safe commit each)

### Slice S1 — `/v1/tx/introspect`
New `Amaru.Treasury.Api.Introspect` module (pure `introspectTx`), the two
introspect carriers in `Api/Types.hs`, the route + pure `hIntrospect` field +
`mkServer` wiring in `Server.hs`, the binary wiring in
`app/amaru-treasury-tx-api/Main.hs`, the `.cabal` exposed-module + test-module
entries, and `test/unit/.../Api/IntrospectSpec.hs`.
Proves SC-001, SC-002, FR-005 (pure-type).

### Slice S2 — `/v1/verify-witness`
New `Amaru.Treasury.Api.VerifyWitness` module (pure total `verifyWitness`), the
two verify carriers in `Api/Types.hs`, the route + pure `hVerifyWitness` field
+ `mkServer` wiring in `Server.hs`, the binary wiring in `Main.hs`, the
`.cabal` entries, and `test/unit/.../Api/VerifyWitnessSpec.hs`.
Proves SC-003, SC-004, SC-005.

Slices are serial (both touch `Server.hs` + `Api/Types.hs` + `Main.hs`); S1
establishes the pure-field + route pattern, S2 mirrors it. Each is usable on
its own.

## TDD

Standard unit harness exists (`test-suite unit-tests`, `just unit`). RED:
write the failing spec first against the `118-vault-witness` fixtures. GREEN:
minimal pure function + wiring. No new fixtures — the wrong-key vault identity
+ `createWitness` + the `106` tx body generate every negative case in-test.

## Gate

`./gate.sh` = `git diff --check` + `just build` + `just unit` +
`just format-check` + `just hlint` (run via `nix develop -c`; also fired
automatically by the repo `pre-commit` hook). Focused re-run:
`nix develop -c just unit "Introspect"` / `"VerifyWitness"`.
