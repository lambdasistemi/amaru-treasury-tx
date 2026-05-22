# d6c14625 references golden

Golden CBOR fixture for the rationale metadatum (CIP-1694 label 1694)
of the mainnet transaction
`d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d`
— an `ops_and_use_cases` disburse to Jacob Finkelman that emits two
`references[]` entries (an RCA contract and an invoice).

## Provenance

| Field        | Value                                                            |
|--------------|------------------------------------------------------------------|
| Tx hash      | `d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d` |
| Block hash   | `75906b190944e4a8bd7c5fbaed1e25f7c908d381fd21231ddc9398594ad224de` |
| Block height | `13357663`                                                       |
| Slot         | `185979190`                                                      |
| Fetch date   | `2026-05-22` (UTC)                                               |
| Source       | Blockfrost mainnet `/txs/{hash}/metadata/cbor`                   |

## URL used

```
GET https://cardano-mainnet.blockfrost.io/api/v0/txs/d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d/metadata/cbor
```

The response wraps the label-1694 metadatum in a single-entry map
keyed by the label (`a1 19 06 9e <value>`). The 4-byte wrapper is
stripped; `rationale.cbor` holds the raw bytes of the metadatum value
that `rationaleMetadatum` returns.

## Files

- `rationale.cbor` — canonical CBOR of the label-1694 metadatum value
  (the byte-for-byte chain-emitted serialisation).
- `intent.json` — the wizard-output intent fixture whose rationale
  body, when fed through the typed `RationaleBody` constructor with
  `rbReferences`, must re-serialise to `rationale.cbor`. The
  `references` field on `intent.json` is currently a literal JSON
  passthrough — slice S2 wires the FromJSON path on `RationaleJSON`;
  S1's `ReferencesSpec` builds the metadatum directly from the
  `RationaleBody { rbReferences = [...] }` constructor.
