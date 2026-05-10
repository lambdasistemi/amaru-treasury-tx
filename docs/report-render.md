# Report renderer

`report-render` turns the JSON build-output envelope from
`tx-build --report` into the pre-signing review artifact for multisig
reviewers. The Markdown is mechanical: it is generated from the
envelope, its inline intent, the unsigned transaction CBOR, and the
nested transaction report.

## Build-output envelope

The JSON contract is top-level intent plus top-level result. The
inline intent is the same unified intent JSON that `tx-build` decoded;
it is the only carrier of transaction type and scope.

Successful builds carry the unsigned transaction bytes and mechanical
report under `result`:

```json
{
  "intent": {},
  "result": {
    "tx-cbor": "84a4...",
    "report": {}
  }
}
```

Failed builds that happen after intent decoding carry the same inline
intent and a structured failure:

```json
{
  "intent": {},
  "result": {
    "failure": {
      "code": "validation-failed",
      "message": "..."
    }
  }
}
```

If the intent cannot be decoded, there is no report envelope: the
intent is required context for both the transaction type and the
renderer.

## CLI

```bash
amaru-treasury-tx report-render \
    --in report.json \
    --out report.md \
    --metadata metadata-mainnet.json
```

With no flags, `report-render` reads the envelope from stdin and
writes Markdown to stdout. `--in -` and `--out -` are explicit aliases
for those streams. There is no `--intent` argument; renderer input is
self-contained.

Failure handling is fail-closed:

- malformed envelopes, missing `intent`, missing `result`, missing
  success `tx-cbor`, or missing success `report` exit non-zero;
- failure envelopes print a diagnostic and exit non-zero because they
  are not signable transaction reviews;
- output write failures exit non-zero and name the destination path.

## Identity resolution

Identity labels are resolved from treasury metadata, built-in constants, script-hash derivation, embedded intent, and unresolved fallback, in that order. Resolved labels are role labels such as
`network_compliance treasury`, `Sundae swap-order [network_compliance]`,
or `network_compliance scope owner`.

Unresolved addresses and signer hashes are still rendered, but never
as bare full identifiers. They are wrapped as `unresolved (...)` with
a truncated fallback so reviewers can see that no source matched.

## Determinism

Rendering is offline and deterministic. It does not query the chain,
read the clock, call external services, or parse the transaction CBOR
to discover semantics. The transaction CBOR is still required under
`result.tx-cbor` and is shown as a fingerprint in the leading section
so reviewers can bind the Markdown facts to the unsigned transaction
bytes they are signing.

## Helper

`scripts/ops/build-swop` is the operator helper for producing a review
bundle from an intent:

```bash
scripts/ops/build-swop --out swap-run < intent.json
```

By default it writes:

- `swap-run/swap.cbor.hex`
- `swap-run/report.json`
- `swap-run/report.md`

Use `--no-markdown` to opt out of Markdown rendering while still
writing `report.json`:

```bash
scripts/ops/build-swop --out swap-run --no-markdown < intent.json
```

The helper removes any previous `report.md` before each run, including
`--no-markdown`, so a stale Markdown review artifact is not mistaken
for the current build.
