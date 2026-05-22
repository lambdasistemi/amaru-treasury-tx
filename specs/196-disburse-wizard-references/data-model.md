# Data Model: `RationaleReference` + `RationaleBody.rbReferences`

**Phase**: 1 (design & contracts)
**Module**: `lib/Amaru/Treasury/AuxData.hs`

## Entities

### `RationaleReference`

A single external-document pointer attached to a disburse rationale.

```haskell
data RationaleReference = RationaleReference
    { rrUri :: !Text
    -- ^ Full URI of the reference document.
    -- @ipfs://\<CID\>@ is the canonical shape; @https://@ and
    -- @ar://@ also supported. Each chunk of the serialised metadatum
    -- string must fit under the 64-byte Cardano ledger cap. The
    -- IPFS-aware split (R2 in research.md) handles the common case;
    -- non-IPFS URIs longer than 64 bytes fail at serialisation.
    , rrType :: !Text
    -- ^ Reference type per the SundaeSwap metadata spec.
    -- Default @\"Other\"@ when unspecified at the CLI.
    , rrLabel :: !Text
    -- ^ Human-readable label. A literal @\" - \"@ separator marks
    -- a 3-chunk split (matches the d6c14625 precedent); otherwise
    -- emitted as a single chunk. Each chunk must fit under the
    -- 64-byte cap.
    }
    deriving stock (Eq, Show)
```

**Validation rules**:
- `rrUri ≥ 1 byte` after trimming; no leading/trailing whitespace.
- `rrType ≥ 1 byte`; default `"Other"` if absent.
- `rrLabel ≥ 1 byte`.
- Every chunk produced by R2/R3 splitters ≤ 64 bytes; serialiser
  raises a named error otherwise.

**State transitions**: none — `RationaleReference` is a value
record. Created by the CLI parser or read from `intent.json`,
serialised once into the rationale metadatum, never mutated.

---

### `RationaleBody` (modified)

Existing record gains one field, default `[]`:

```haskell
data RationaleBody = RationaleBody
    { rbEvent :: !Text
    , rbLabel :: !Text
    , rbDescription :: ![Text]
    , rbDestinationLabel :: !Text
    , rbJustification :: ![Text]
    , rbReferences :: ![RationaleReference]
    -- ^ NEW. Default @[]@ to preserve existing golden CBOR
    -- output for every non-disburse caller. Populated by
    -- @disburse-wizard --reference-*@ flags.
    }
    deriving stock (Eq, Show)
```

**Validation rules**: as before, plus `rbReferences` may be empty
(common case for non-disburse callers).

**State transitions**: none.

---

## Relationships

```text
disburse-wizard (CLI)
   │
   │ --reference-uri ipfs://… --reference-label "Invoice - …"
   ▼
intent.json (rationale.references[])
   │
   │ parseDisburseIntent  (lib/Amaru/Treasury/IntentJSON.hs)
   ▼
RationaleJSON.rjReferences :: [RationaleReference]
   │
   │ translateDisburse  (lib/Amaru/Treasury/IntentJSON.hs)
   ▼
RationaleBody.rbReferences :: [RationaleReference]
   │
   │ rationaleMetadatum  (lib/Amaru/Treasury/AuxData.hs)
   ▼
Metadatum (label 1694, body.references = List [Map …])
   │
   │ Conway tx auxiliary data
   ▼
on-chain rationale
```

---

## Helpers (internal, AuxData.hs)

Two pure functions added inside `AuxData.hs`. Exported only as
needed for the test suite.

```haskell
-- | Split a URI into Metadatum-string chunks per R2.
--   ipfs://<CID> → [ "ipfs://", "<CID>" ]
--   <other>      → [ <other> ]
--   Fails (returns Left) if any chunk exceeds the 64-byte cap.
splitUri :: Text -> Either String [Text]

-- | Split a label into Metadatum-string chunks per R3.
--   "lhs - rhs"  → [ "lhs", " - ", "rhs" ]
--   "lhs"        → [ "lhs" ]
--   Fails (returns Left) if any chunk exceeds the 64-byte cap.
splitLabel :: Text -> Either String [Text]
```

Both helpers participate in property tests (round-trip + length cap)
via the existing QuickCheck rig.

---

## Schema (intent.json delta)

Added under the disburse rationale block in
`lib/Amaru/Treasury/IntentJSON/Schema.hs`:

```json
{
  "references": {
    "type": "array",
    "default": [],
    "items": {
      "type": "object",
      "required": ["uri", "label"],
      "properties": {
        "uri":   { "type": "string", "minLength": 1 },
        "@type": { "type": "string", "minLength": 1, "default": "Other" },
        "label": { "type": "string", "minLength": 1 }
      },
      "additionalProperties": false
    }
  }
}
```

- `references` is optional (default `[]`); existing intents continue
  to validate.
- Per-item: `uri` and `label` required; `@type` optional with default
  `"Other"`.
- `additionalProperties: false` keeps the shape disciplined; future
  fields require a deliberate schema bump.

---

## Out of model

- `destination.details.anchorUrl` / `destination.details.anchorDataHash`
  — separate ticket if/when a vendor needs destination-side anchors.
- Reference-level `anchorDataHash` (e.g. blake2b of the IPFS-pinned
  file) — not in the d6c14625 precedent; add as a follow-up if
  audit consumers ask for content-integrity proof.
- A general-purpose URL chunker for arbitrary URIs ≥ 64 bytes — not
  needed for the current operator set; failing loudly is the spec'd
  behaviour.
