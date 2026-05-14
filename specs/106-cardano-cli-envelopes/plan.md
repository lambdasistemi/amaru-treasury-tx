# Plan — pipeline-friendly envelope / de-envelope commands

Spec: [spec.md](spec.md) · Issue: [#106](https://github.com/lambdasistemi/amaru-treasury-tx/issues/106).

## Design Decisions

### D1. One library module owns envelope encode + decode

New module `Amaru.Treasury.Tx.Envelope` exports:

- `EnvelopeKind = Tx | Witness | SignedTx` — discriminator used by the three encoders.
- `encodeEnvelope :: EnvelopeKind -> ByteString -> ByteString` — pure: takes raw hex bytes, returns the cardano-cli-shaped JSON envelope bytes.
- `decodeEnvelope :: ByteString -> Either EnvelopeError ByteString` — pure: takes envelope JSON bytes, returns the inner `cborHex` bytes (raw).
- `EnvelopeError` — typed sum (`NotJson`, `JsonShape`, `WrongEra`, `MissingFields`, …), each with enough context to render a one-line operator-readable diagnostic.
- `renderEnvelopeError :: EnvelopeError -> Text`.

The four subcommands are thin shells: they read stdin, call the pure function, write stdout (or write to stderr and exit 1 on error). No IO inside the encode/decode core — that keeps unit testing trivial.

### D2. `de-envelope` auto-detects `EnvelopeKind` from the `type` field; no flag

The encoder needs an `EnvelopeKind` because it's manufacturing the `type` string. The decoder doesn't: it reads the string out of the envelope. That's why we have three `envelope-*` commands (one per kind) but only one `de-envelope`.

### D3. Era validation: literal-substring check for `"ConwayEra"`

`decodeEnvelope` validates that the `type` string contains the substring `"ConwayEra"`. Any other era tag (`ShelleyEra`, `AllegraEra`, `MaryEra`, `AlonzoEra`, `BabbageEra`, or even a misspelling) is rejected with `WrongEra` carrying the offending `type` value.

We deliberately do **not** parse the era out of the `type` field (e.g. `"Unwitnessed Tx ConwayEra"` → `("Unwitnessed Tx", ConwayEra)`). The check is "this envelope is Conway-era"; we don't need a structured era ADT.

### D4. Output format pinned to cardano-cli's wire shape

`encodeEnvelope` emits:

- Three top-level keys, in order: `type`, `description`, `cborHex`.
- Four-space indentation.
- Single trailing newline.

Canonical `description` per kind:

- `Tx` → `"Ledger Cddl Format"`
- `Witness` → `"Key Witness ShelleyEra"` (cardano-cli quirk: the witness format is labelled Shelley even in Conway era).
- `SignedTx` → `"Ledger Cddl Format"`

The cardano-cli oracle fixture (S4) pins these strings against a real cardano-cli artefact.

### D5. Stdin trimming, stdout newline

`envelope-*` reads stdin, strips a single trailing `\n` if present (the common shell-pipe artefact), and puts the result into `cborHex` verbatim. No other whitespace handling — internal whitespace would be a semantic problem the wrapper has no business fixing.

`de-envelope` writes the extracted `cborHex` followed by a single `\n` so the output composes cleanly into downstream commands (which already accept a trailing newline on their stdin, per the `attach-witness` and `submit` decoders).

Both `envelope-*`'s JSON output and `de-envelope`'s hex output end in exactly one `\n`. Composition `envelope-tx | de-envelope` round-trips the input byte-for-byte (modulo that trailing newline).

### D6. Errors go to stderr with exit code 1; nothing to stdout on error

The four commands are filters. Mixing errors into stdout would corrupt downstream parsers. On any failure, stderr gets a one-line diagnostic; stdout is empty; exit code is 1. This matches the existing `attach-witness` / `submit` error model.

### D7. Slicing into vertical commits

Five vertical commits, each bisect-safe (compiles, tests pass on its own, leaves `tx-build | attach-witness | submit` unchanged):

1. `docs(106): spec` — landed (commit `0bd692a`).
2. `feat(106): envelope-* wrap commands` — `Amaru.Treasury.Tx.Envelope` (encode side only), three CLI subcommands, unit tests. After this commit, `envelope-tx`, `envelope-witness`, `envelope-signed-tx` work end-to-end.
3. `feat(106): de-envelope unwrap command` — extends the library with the decode side, adds the `de-envelope` CLI subcommand, unit tests for happy path + edge cases (non-JSON, wrong era, malformed JSON, missing fields).
4. `test(106): cardano-cli oracle byte-identity` — checked-in fixture under `test/fixtures/106-cardano-cli-oracle/` (real `cardano-cli` build/witness/assemble outputs + a `fixture-source.md` capturing the `cardano-cli --version`). New `EnvelopeOracleSpec` asserts `envelope-witness` of the raw bytes equals the cardano-cli `*.witness.json` byte-for-byte, and `de-envelope` of the cardano-cli envelope equals the raw bytes.
5. `docs(106): cardano-cli compatibility section` — `docs/swap.md` gains a "Composing with cardano-cli" section showing the four pipeline shapes (us → cli, cli → us, round-trip-through-cli, round-trip-through-us).

Each commit GPG-signed, force-pushed to `feat/106-cardano-cli-envelopes`.

### D8. Gate

`specs/106-cardano-cli-envelopes/gate.sh`: `nix develop --quiet -c just ci`.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `cardano-cli`'s emitted byte shape might not match `aeson`'s pretty-printer for edge cases (Unicode in `description`, very long `cborHex`). | Pin `confIndent = Spaces 4`, `confTrailingNewline = False` (we add our own `"\n"`), `confCompare = keyOrder ["type","description","cborHex"]`. Confirm byte-identity against the **real** cardano-cli oracle fixture, not just a synthetic envelope. If `aeson`'s pretty-printer diverges, implement the JSON emitter by hand (it's three concatenations — `"{\n    \"type\": "` etc.). |
| `description` for `TxWitness ConwayEra` is `"Key Witness ShelleyEra"` (cardano-cli quirk). If someone reads the spec and assumes the description is era-significant, they may be misled. | Documented in spec.md edge cases and in the Haddock for `encodeEnvelope`. The decoder ignores `description`. |
| Auto-detected env-kind in `de-envelope` means we accept all three Conway tx tags (`Unwitnessed`, `Witnessed`, `Signed`) under `de-envelope`. An operator who pipes a `Signed Tx` envelope into `attach-witness` won't get an error from `de-envelope` even though `attach-witness` expects an unsigned body. | Acceptable: this is layered. `de-envelope` does shape validation; `attach-witness` does semantic validation. Combining them re-creates the strict path. If we wanted stricter, we'd add a `--expect tx-body` flag, which is out-of-scope for this PR. |
| The library exports both `encodeEnvelope` and `decodeEnvelope`. If they're added in two separate commits (S2 then S3) the module is incomplete in S2. | Acceptable: S2's commit only exports `encodeEnvelope`; S3 adds `decodeEnvelope`. Bisect-safe — both compile. The four `envelope-*` commands don't need the decoder. |
| `attach-witness` and `submit` decoders strip leading/trailing whitespace from their stdin hex. `de-envelope` emits hex followed by a single `\n`. Round-trip through the pipe `cardano-cli-output | de-envelope | attach-witness` must work; confirm with a fixture-driven test. | Covered by S4 oracle fixture: pipe a real cardano-cli `tx.body.json` through `de-envelope`, hand to `attach-witness` programmatically (in-process), assert success. |
| `envelope-*` commands trim a single trailing newline before encoding. If the operator pipes the literal output of `tx-build` (which emits a trailing newline) we get the right thing. If they `cat` a file produced by `printf` without a final newline, we still get the right thing. If they `cat` a file with two trailing newlines, we leave the second one in `cborHex` — which is wrong. | Trim *all* trailing whitespace from stdin, not just one newline. Document this in the spec and Haddock. (Update spec.md FR-1..FR-3 in this plan iteration: trim all trailing whitespace.) |

## Live re-verification before push

Per the spec's success criteria, run against a real `cardano-cli`-produced witness fixture:

```bash
# Produce oracle artefacts (one-off, output bundled into the fixture commit)
cardano-cli conway transaction build-raw --tx-in "$TX_IN" --tx-out "$TX_OUT" \
    --fee 200000 --out-file /tmp/106/tx.body.json
cardano-cli conway transaction witness --tx-body-file /tmp/106/tx.body.json \
    --signing-key-file /tmp/106/signer.skey --out-file /tmp/106/witness.json
cardano-cli conway transaction assemble --tx-body-file /tmp/106/tx.body.json \
    --witness-file /tmp/106/witness.json --out-file /tmp/106/signed.json

# Verify our encoder is byte-identical:
RAW_BODY="$(jq -r .cborHex /tmp/106/tx.body.json)"
echo "$RAW_BODY" | amaru-treasury-tx envelope-tx | cmp - /tmp/106/tx.body.json
# → no output, exit 0

# Verify our decoder is byte-identical:
cat /tmp/106/witness.json | amaru-treasury-tx de-envelope \
    | diff - <(jq -r .cborHex /tmp/106/witness.json | cat -; echo)
# → no diff
```

## Spec amendments folded into this plan

While drafting the plan I noticed FR-1..FR-3 say "trailing-newline-trimmed" but the right rule is "trailing-whitespace-trimmed". When S2 lands I'll update spec.md FR-1..FR-3 and the corresponding edge case bullets in the same commit.

## Gate

`specs/106-cardano-cli-envelopes/gate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nix develop --quiet -c just ci
```
