# Tasks — pipeline-friendly envelope / de-envelope commands

Spec: [spec.md](spec.md) · Plan: [plan.md](plan.md) · Issue: [#106](https://github.com/lambdasistemi/amaru-treasury-tx/issues/106) · PR: [#115](https://github.com/lambdasistemi/amaru-treasury-tx/pull/115).

This starts after S1 (`docs(106): spec`) and the plan gate. Each implementation slice below lands as one StGit patch: RED tests, GREEN code, docs, and gate evidence stay together.

TDD rule for this feature: the `cardano-cli` oracle is the first behavioral test source. Do not write `Amaru.Treasury.Tx.Envelope` or CLI production code until the oracle fixture and focused oracle tests have been added, run, and observed failing for the expected reason.

[FR-1]: spec.md#subcommands
[FR-2]: spec.md#subcommands
[FR-3]: spec.md#subcommands
[FR-4]: spec.md#subcommands
[FR-5]: spec.md#output-format
[FR-6]: spec.md#output-format
[FR-7]: spec.md#validation
[FR-8]: spec.md#validation
[FR-9]: spec.md#validation
[FR-10]: spec.md#untouched

## S2 — `envelope-*` wrap commands, oracle first *(one reviewed commit)*

| Task | Type | FRs | Output |
|---|---|---|---|
| T2.1 | ORACLE | [FR-1], [FR-2], [FR-3], [FR-5], [FR-6] | `test/fixtures/106-cardano-cli-oracle/`: generate and check in real `cardano-cli conway transaction build-raw`, `witness`, and `assemble` JSON envelopes plus matching raw `cborHex` files. Add `fixture-source.md` with `cardano-cli --version`, exact commands, and refresh notes. |
| T2.2 | RED | [FR-1], [FR-2], [FR-3], [FR-5], [FR-6] | `test/golden/EnvelopeOracleSpec.hs`: add byte-identity tests proving `encodeEnvelope Tx`, `encodeEnvelope Witness`, and `encodeEnvelope SignedTx` over the oracle raw hex produce the corresponding `cardano-cli` envelopes byte-for-byte. Run the focused golden test and record the expected failure before production code exists. |
| T2.3 | RED | [FR-1], [FR-2], [FR-3], [FR-10] | `test/unit/Amaru/Treasury/Cli/EnvelopeSpec.hs`: add parser/runner tests for `envelope-tx`, `envelope-witness`, and `envelope-signed-tx`; include a parser regression proving `attach-witness`, `submit`, and `tx-build` option shapes are unchanged. |
| T2.4 | RED | [FR-1], [FR-2], [FR-3], [FR-5], [FR-6] | `test/unit/Amaru/Treasury/Tx/EnvelopeSpec.hs`: add supporting encode-side cases derived from the oracle contract: key order, four-space indentation, canonical descriptions, one trailing newline, empty stdin behavior, and trailing-whitespace trimming. |
| T2.5 | GREEN | [FR-1], [FR-2], [FR-3], [FR-5], [FR-6] | `lib/Amaru/Treasury/Tx/Envelope.hs`: add `EnvelopeKind`, encode-side type/description mapping, and `encodeEnvelope :: EnvelopeKind -> ByteString -> ByteString` with the pinned oracle byte shape. |
| T2.6 | GREEN | [FR-1], [FR-2], [FR-3], [FR-10] | `lib/Amaru/Treasury/Cli/Envelope.hs`, `lib/Amaru/Treasury/Cli.hs`, `app/amaru-treasury-tx/Main.hs`, and `amaru-treasury-tx.cabal`: add the three wrapper subcommands as stdin/stdout filters and register new modules/tests/fixtures. Do not edit `lib/Amaru/Treasury/Cli/AttachWitness.hs`, `lib/Amaru/Treasury/Cli/Submit.hs`, or `lib/Amaru/Treasury/Cli/TxBuild.hs`. |
| T2.7 | docs | [FR-1], [FR-2], [FR-3] | `specs/106-cardano-cli-envelopes/spec.md` and `lib/Amaru/Treasury/Tx/Envelope.hs`: fold in the plan's trimming amendment and add concise Haddock for the encode-side oracle contract. |
| T2.8 | gate | [FR-1], [FR-2], [FR-3], [FR-5], [FR-6], [FR-10] | Re-run the focused oracle tests now green, then run `nix develop --quiet -c just ci`; commit as `feat(106): envelope-* wrap commands`; push `feat/106-cardano-cli-envelopes`; update PR #115 with the red/green evidence. |

## S3 — `de-envelope` unwrap command, oracle first *(one reviewed commit)*

| Task | Type | FRs | Output |
|---|---|---|---|
| T3.1 | RED | [FR-4] | `test/golden/EnvelopeOracleSpec.hs`: before writing decode code, add oracle decode tests proving each checked-in Conway envelope from `test/fixtures/106-cardano-cli-oracle/` de-envelopes to its matching raw `cborHex` bytes plus exactly one trailing newline. Run the focused golden test and record the expected failure. |
| T3.2 | RED | [FR-7] | `test/fixtures/106-cardano-cli-oracle/`: add a stale non-Conway envelope fixture; `test/golden/EnvelopeOracleSpec.hs` asserts `de-envelope` rejects it and stderr includes the offending era string. |
| T3.3 | RED | [FR-8], [FR-9] | `test/unit/Amaru/Treasury/Tx/EnvelopeSpec.hs` and `test/unit/Amaru/Treasury/Cli/EnvelopeSpec.hs`: add supporting edge/error cases for first non-whitespace byte not `{`, malformed JSON, missing fields, wrong-typed fields, empty stdout on failure, stderr diagnostics, and exit code 1. |
| T3.4 | GREEN | [FR-4], [FR-7], [FR-8], [FR-9] | `lib/Amaru/Treasury/Tx/Envelope.hs`: add `decodeEnvelope`, `EnvelopeError`, and `renderEnvelopeError` with enough context for one-line operator diagnostics. |
| T3.5 | GREEN | [FR-4], [FR-7], [FR-8], [FR-9], [FR-10] | `lib/Amaru/Treasury/Cli/Envelope.hs`, `lib/Amaru/Treasury/Cli.hs`, and `app/amaru-treasury-tx/Main.hs`: add `de-envelope` as a stdin/stdout filter and route errors to stderr without touching existing raw-hex commands. |
| T3.6 | docs | [FR-4], [FR-7], [FR-8], [FR-9] | `lib/Amaru/Treasury/Tx/Envelope.hs`: add Haddock for accepted Conway envelope kinds, ignored `description`, accepted extra keys, and decode errors. |
| T3.7 | gate | [FR-4], [FR-7], [FR-8], [FR-9], [FR-10] | Re-run the focused oracle tests now green, then run `nix develop --quiet -c just ci`; commit as `feat(106): de-envelope unwrap command`; push `feat/106-cardano-cli-envelopes`; update PR #115 with the red/green evidence. |

## S4 — executable oracle replay + raw-hex regression *(one reviewed commit)*

The oracle is already introduced as the RED source in S2/S3. This slice keeps the plan's oracle hardening as executable-level replay and untouched-pipeline evidence, not as the first proof.

| Task | Type | FRs | Output |
|---|---|---|---|
| T4.1 | RED | [FR-1], [FR-2], [FR-3], [FR-4], [FR-5], [FR-6] | `test/golden/EnvelopeOracleSpec.hs` or `scripts/smoke/cardano-cli-envelope-oracle`: add black-box executable checks that pipe oracle raw files through `amaru-treasury-tx envelope-*` and oracle envelopes through `amaru-treasury-tx de-envelope`, comparing stdout byte-for-byte to the fixture files. |
| T4.2 | RED | [FR-4], [FR-10] | `test/golden/EnvelopeOracleSpec.hs`: add an in-process regression that `de-envelope` output from the oracle tx body remains consumable by the existing raw-hex attach-witness path. |
| T4.3 | RED | [FR-10] | `scripts/smoke/tx-build-pipe` or a focused golden/unit check: pin the v0.2.5.1 raw `tx-build \| attach-witness \| submit` path as byte-identical after the envelope filters are present. |
| T4.4 | GREEN | [FR-1], [FR-2], [FR-3], [FR-4], [FR-5], [FR-6], [FR-10] | `amaru-treasury-tx.cabal`, `justfile`, or smoke/golden registration files: wire the executable oracle replay into the normal gate. Adjust product code only if this executable replay exposes a mismatch not already caught by S2/S3. |
| T4.5 | docs | [FR-1], [FR-2], [FR-3], [FR-4] | `test/fixtures/106-cardano-cli-oracle/fixture-source.md`: update with any extra replay command needed to reproduce the executable oracle checks. |
| T4.6 | gate | [FR-1], [FR-2], [FR-3], [FR-4], [FR-5], [FR-6], [FR-10] | Run `nix develop --quiet -c just ci`; commit as `test(106): cardano-cli oracle byte-identity`; push `feat/106-cardano-cli-envelopes`; update PR #115. |

## S5 — cardano-cli compatibility docs *(one reviewed commit)*

| Task | Type | FRs | Output |
|---|---|---|---|
| T5.1 | docs | [FR-1], [FR-2], [FR-3], [FR-4] | `docs/swap.md`: add "Composing with cardano-cli" with the four planned pipeline shapes: us to cli, cli to us, round-trip-through-cli, and round-trip-through-us. |
| T5.2 | docs | [FR-7], [FR-8], [FR-9] | `docs/swap.md`: add the operator-facing failure examples for stale-era envelopes and non-envelope input, linking back to the filters rather than changing raw-hex command docs. |
| T5.3 | GREEN | [FR-10] | No product-code changes in this slice; confirm `attach-witness`, `submit`, and `tx-build` docs still describe raw CBOR hex contracts. |
| T5.4 | gate | [FR-1], [FR-2], [FR-3], [FR-4], [FR-7], [FR-8], [FR-9], [FR-10] | Run `nix develop --quiet -c just ci`; commit as `docs(106): cardano-cli compatibility section`; push `feat/106-cardano-cli-envelopes`; update PR #115. |

## Folding & bisect-safety summary

S2, S3, S4, and S5 each land as one StGit patch. S2 and S3 start from the real `cardano-cli` oracle, then add supporting unit coverage, then implement the minimum code to turn those RED tests green. S4 is not allowed to be the first oracle check; it only replays the already-established oracle through the executable and pins the raw-hex regression. Every pushed patch must leave the existing raw-hex pipeline unchanged.

## Reshape order

```text
s1-docs   — docs(106): spec
s2-plan   — docs(106): plan
s3-tasks  — docs(106): tasks
S2        — feat(106): envelope-* wrap commands
S3        — feat(106): de-envelope unwrap command
S4        — test(106): cardano-cli oracle byte-identity
S5        — docs(106): cardano-cli compatibility section
```
