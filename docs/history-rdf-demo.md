# Treasury history RDF demo

The history surface exposes a fixed RDF analysis catalog over indexed
treasury transactions. Callers choose names; they do not submit raw
SPARQL or SHACL.

Runtime requirements:

- `cq-rdf` emits Cardano ledger RDF from each stored raw transaction
  CBOR payload.
- Apache Jena `arq` runs named SPARQL queries.
- Apache Jena `shacl` validates named SHACL shapes.

The Nix-built `amaru-treasury-tx` and `amaru-treasury-tx-api`
wrappers put those tools on `PATH`.

## CLI

Plain history rows still work:

```bash
amaru-treasury-tx history \
  --scope core_development \
  --indexer-db /var/lib/amaru-treasury/indexer
```

The same command accepts shared filters:

```bash
amaru-treasury-tx history \
  --scope core_development \
  --indexer-db /var/lib/amaru-treasury/indexer \
  --role disburse \
  --direction outbound \
  --asset ada \
  --since 123000 \
  --until 124000 \
  --limit 20
```

Run a named SPARQL query:

```bash
amaru-treasury-tx history \
  --scope core_development \
  --indexer-db /var/lib/amaru-treasury/indexer \
  --rdf-query asset-flow
```

Run a named SHACL validation:

```bash
amaru-treasury-tx history \
  --scope core_development \
  --indexer-db /var/lib/amaru-treasury/indexer \
  --shacl history-entry
```

`--rdf-query` and `--shacl` are mutually exclusive.

## HTTP

Filtered history rows:

```bash
curl \
  'http://127.0.0.1:8080/v1/scope/core_development/txs?role=disburse&direction=outbound&asset=ada'
```

Named SPARQL:

```bash
curl \
  'http://127.0.0.1:8080/v1/scope/core_development/txs/query?name=asset-flow'
```

Named SHACL:

```bash
curl \
  'http://127.0.0.1:8080/v1/scope/core_development/txs/shacl?name=history-entry'
```

## Catalog

SPARQL names:

| Name | Payload required | Purpose |
| :--- | :--------------- | :------ |
| `history-entries` | no | ATX metadata rows: slot, txid, scope, role, direction. |
| `tx-count` | yes | Count Cardano transaction subjects emitted by `cq-rdf`. |
| `asset-flow` | yes | Output asset movements, including ADA and native assets. |
| `spend-edges` | yes | Input-to-output joins when producer and consumer are both indexed. |
| `entity-occurrences` | no | Operator overlay entity identifier counts when overlay triples exist. |

SHACL names:

| Name | Payload required | Purpose |
| :--- | :--------------- | :------ |
| `history-entry` | no | Validate ATX metadata shape for every indexed history row. |
| `indexed-tx-body` | yes | Validate that history entries point at emitted Cardano transaction body subjects. |
