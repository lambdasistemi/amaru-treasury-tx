# Treasury history RDF case study

Treasury transaction history is a useful Cardano Ledger RDF test bed
because it combines application metadata with ledger structure:

- ATX knows the scope, treasury role, direction, and index slot.
- The tx-history indexer stores raw transaction CBOR payloads.
- `cq-rdf body` turns each payload into Cardano ledger Turtle.
- Fixed SPARQL queries and SHACL shapes analyze the combined lattice.

This gives the CLI and HTTP server the same semantic analysis path.

## Lattice

Each indexed row contributes one ATX metadata subject:

```turtle
<urn:amaru-treasury-tx:history:0>
  a atx:HistoryEntry ;
  atx:tx <urn:cardano:tx:...> ;
  atx:txid "..." ;
  atx:slot 123 ;
  atx:scope "core_development" ;
  atx:role "disburse" ;
  atx:direction "outbound" .
```

Rows with raw CBOR payloads also contribute the Cardano transaction
body graph emitted by `cq-rdf`.

## Demo queries

`history-entries` is the sanity query. It proves that the application
metadata graph is present before body-level analysis starts.

`tx-count` is the smallest body-level query. It proves that raw
transaction payloads were available and that `cq-rdf` emitted Cardano
transaction subjects.

`asset-flow` is the operator-facing payment audit. It reports the txid,
asset, quantity, and destination for output asset movements.

## Case-study queries

`spend-edges` is the cross-transaction join. It only returns rows when
the indexed window contains both the producing transaction and the
consuming transaction.

`entity-occurrences` follows the Cardano Ledger RDF overlay pattern. It
returns rows when an operator overlay introduces `cardano:Entity`
identifier triples into the lattice.

## SHACL gates

`history-entry` validates the ATX metadata contract:

- exactly one `atx:tx` IRI
- exactly one string `atx:txid`
- exactly one integer `atx:slot`
- exactly one string `atx:scope`
- exactly one string `atx:role`
- exactly one string `atx:direction`

`indexed-tx-body` validates the CBOR-backed contract: every
`atx:HistoryEntry` must point at a `cardano:Transaction` emitted from
the raw transaction payload.

## Operational reading

On devnet, run `history-entry` first. If it fails, the ATX metadata row
shape is wrong and body analysis is not meaningful.

Run `tx-count` next. If it returns zero for a populated scope, the
history rows were indexed without usable transaction payloads or the
runtime cannot reach `cq-rdf`.

Run `asset-flow` for payment review and `spend-edges` after the devnet
has advanced far enough to contain both sides of relevant spends.
