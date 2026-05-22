# Research: `disburse-wizard --reference` flags + `RationaleBody.references`

**Phase**: 0 (outline & research)
**Status**: complete — no open `NEEDS CLARIFICATION` markers.

## R1. Reference encoding shape on chain

**Decision**: emit per-reference object as
`{ "uri": [chunk, ...], "@type": "Other", "label": [chunk, ...] }`,
matching the d6c14625 mainnet precedent byte-for-byte.

**Rationale**: the SundaeSwap treasury-contracts metadata spec at the
pinned commit `ad4316d0d36cdef780f85fc2ec8b307e645ddc2a` documents
`uri`/`@type`/`label` as the per-reference structure; the d6c14625
mainnet tx is the only on-chain instance against the same
permissions+treasury contract set we ship into, so its serialisation
is the load-bearing contract for indexers and downstream consumers.

**Alternatives considered**:
- *Spec-strict literal strings (no list)*: rejected — spec is
  permissive on multiplicity of inner values; on-chain precedent uses
  lists; matching precedent keeps the SundaeSwap dashboards working.
- *Custom `@type` values per reference (`"Contract"`, `"Invoice"`,
  `"PaymentInstruction"`)*: rejected for now — the precedent uses
  `"Other"`; introducing custom types without coordinating with
  SundaeSwap's indexer schema risks breaking aggregation. Default to
  `"Other"`, leave the flag open for future operators who coordinate
  with downstream consumers.

## R2. URI chunking strategy

**Decision**: if `rrUri` begins with `ipfs://`, emit a 2-element list
`["ipfs://", rest]` where `rest` is the substring after the `ipfs://`
prefix. Otherwise emit a 1-element list `[rrUri]`. Verify each chunk
≤ 64 bytes at serialisation time; fail with a clear error if a chunk
exceeds the cap.

**Rationale**: Cardano ledger caps metadatum strings at 64 bytes
(`maxMetadatumStringLength`). Concrete sizes:
- `"ipfs://"` = 7 bytes
- CIDv1 (`bafy…` / `bafk…`) = 59 bytes
- Joined = 66 bytes → over the cap; would fail intent-validation and
  abort `tx-build` with an obscure metadatum error.
- The precedent's `["ipfs://", "<CID>"]` split sidesteps this and is
  already what consumers parse.

For non-IPFS URIs (HTTPS, arweave, future schemes), most fit under 64
bytes verbatim. Long URLs would need a general-purpose chunker that
honours UTF-8 boundaries — explicitly **out of scope** (per spec).
Failing loudly with a named error gives operators an actionable
message instead of a CBOR decode error downstream.

**Alternatives considered**:
- *Always split on a fixed boundary (e.g. every 64 bytes)*: rejected
  — diverges from precedent and breaks indexer pattern-matching that
  expects `["ipfs://", <CID>]` for IPFS.
- *Auto-base64 for over-64-byte URIs*: rejected — adds a second
  encoding layer that consumers must decode; not in precedent.

## R3. Label chunking strategy

**Decision**: split `rrLabel` on the **first** occurrence of literal
`" - "` (space-dash-space). If present, emit
`[lhs, " - ", rhs]` (3 elements). If absent, emit `[rrLabel]` (1
element). Each chunk ≤ 64 bytes; fail on overflow.

**Rationale**: matches the d6c14625 precedent exactly. Both labels
in that tx use the pattern `"<Doctype> - <description>"` and split on
the literal `" - "`. Splitting on the first occurrence only preserves
operator intent when vendor names contain `" - "` (e.g.
`"Acme - Subsidiary - Invoice 42"` becomes `["Acme", " - ",
"Subsidiary - Invoice 42"]`, not three pieces).

**Alternatives considered**:
- *Always 1-element list, no split*: rejected — diverges from
  precedent and may overflow the 64-byte cap on longer labels.
- *Always 3-element list with empty middle string when no separator*:
  rejected — bloats the metadatum and consumers may not handle empty
  middle gracefully.

## R4. CLI flag grammar

**Decision**: three repeatable flags. `--reference-uri` opens a new
reference slot; subsequent `--reference-type` / `--reference-label`
populate the most-recently-opened slot. `--reference-type` defaults
to `"Other"`. A `--reference-type` or `--reference-label` that
appears before any `--reference-uri` fails with a named error.

**Rationale**: optparse-applicative supports repeatable flag groups
via custom `Parser` combinators that accumulate into a `[Reference]`.
The "uri opens a slot" rule is the simplest mental model for
operators and matches how multi-attribute repeats are conventionally
encoded in CLI tools (e.g. `git commit --trailer key=val
--trailer key2=val2`).

**Alternatives considered**:
- *Single `--reference URI:TYPE:LABEL` colon-separated flag*: rejected
  — colons are common inside URIs (`ipfs://`) and labels; the parsing
  ambiguity is worse than the multi-flag pattern.
- *`--reference-json '{...}'`*: rejected — bash-quoting nightmare
  for operators; defeats the wizard's purpose of typed, friendly CLI.
- *Positional args after the rest*: rejected — variable-arity
  positional args conflict with optparse-applicative's standard shape
  for subcommands.

## R5. Library default + non-disburse callers

**Decision**: `RationaleBody.rbReferences` defaults to `[]` for every
non-`disburse-wizard` caller (`swap-wizard`, `swap-cancel`,
internally also `swapRationaleMetadatum` / `disburseRationaleMetadatum`
helpers). The shared `rationaleMetadatum` function emits `references:
List []` in that case — the same shape today's golden fixtures
already encode.

**Rationale**: Constitution Principle I (faithful port of bash) + V
(test-first golden CBOR). Existing goldens are the authoritative
contract; the new field must not perturb them. Defaulting to `[]`
preserves byte-identical output for every prior fixture.

**Alternatives considered**:
- *Make `rbReferences` a `Maybe [RationaleReference]`*: rejected —
  adds a `Nothing` vs `Just []` distinction with no semantic value
  on chain (both encode to `List []`). Lists are the simpler shape.
- *Add per-wizard variants of `RationaleBody`*: rejected — schema
  fragmentation; every future field would need parallel duplication.

## R6. Schema-side backward compatibility

**Decision**: in the disburse rationale block schema entry add
`"references"` as an **optional** field with a JSON-Schema `default:
[]`. Existing intents without the field continue to validate; new
intents may include it.

**Rationale**: prior `intent.json` files (every checked-in fixture)
omit the field. Making it required would break the entire test suite
and any operator-saved intents. JSON Schema's `default` + omitted-is-OK
semantics are the standard way to extend schemas safely.

## R7. Golden CBOR provenance for d6c14625

**Decision**: extract the rationale metadatum via Blockfrost (`/txs/
{hash}/metadata`), serialise the metadatum value (label 1694) to
canonical CBOR using the same `Cardano.Ledger.Api` path the in-process
builder uses, and check the bytes into
`test/fixtures/disburse/d6c14625-references/rationale.cbor`. Pin the
provenance with a comment in the fixture's `intent.json` naming the
source tx hash, the block, and the fetch date.

**Rationale**: byte-equality against an on-chain artefact is the
strongest possible parity proof. Re-encoding via our own ledger path
(not via Blockfrost's JSON → re-encode) ensures we test the
serialiser the production code actually uses.

**Alternatives considered**:
- *Hand-craft the CBOR bytes in the fixture*: rejected — defeats the
  purpose; we'd be testing the spec against itself, not against
  real chain behaviour.
- *Fetch CBOR directly via `/txs/{hash}/cbor` and slice out aux data*:
  workable but requires CBOR-decoding the whole tx body to isolate
  aux data — adds machinery the test doesn't need. Blockfrost's
  `/metadata` endpoint already gives label-keyed metadatum bytes.

## R8. Cabal version bump (semver)

**Decision**: bump the patch version (e.g. `0.2.11.0 → 0.2.12.0`,
matching the project's `MAJOR.MINOR.PATCH.BUILD` convention).
Disburse-wizard gains new optional flags — additive surface, no
behavioural break — so a minor-position bump within the `0.2.x` line
is appropriate.

**Rationale**: no consumer breaks. Existing intent.json fixtures
parse unchanged. Existing wizard invocations work unchanged. New
fields are opt-in. Patch-position bump is reserved for bug fixes; new
features go in the third component for this project's convention.

**Alternatives considered**:
- *Hold the bump until #196 + a follow-up land together*: rejected —
  the operator (mainnet Cyber Castellum disburse) needs the released
  binary, not a `cabal install` from source.

## R9. Asciinema cast scope

**Decision**: record `docs/assets/asciinema/disburse-wizard-references.cast`
showing a `disburse-wizard` invocation with three `--reference-*`
flag groups (RCA, invoice, signed-email pattern matching the d6c14625
shape), the resulting `intent.json` snippet (`references[]`), and the
`tx-inspect` output showing `body.references[]` in the rendered tree.
No live n2c socket; use a fixture wallet address and fixture
treasury inputs. Redact any real key hashes / mainnet addresses with
preprod or fixture substitutes.

**Rationale**: per the resolve-ticket vertical-deliverables rule for
executable surface changes. The cast is the operator's
quickest-to-grok view of "how do I use these new flags". The
prerequisites (wallet address, metadata.json path, etc.) are
acknowledged via a one-line preamble comment per the asciinema
recording-scope rule.

**Alternatives considered**:
- *Record against mainnet*: rejected — never record actual secret
  values or mainnet addresses tied to real funds.
- *Skip the cast, point operators at the prose docs*: rejected —
  violates the vertical-deliverables rule; the demonstrable run *is*
  the user-readable spec for an exe surface change.
