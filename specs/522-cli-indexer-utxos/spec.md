# spec — #522 CLI reads UTxOs from the treasury API indexer

## Problem

Every CLI command that reads UTxOs opens the node with
`withLocalNodeBackend` and resolves address UTxOs with N2C
`GetUTxOByAddress` (`Cli.Common.queryFlat`, `queryFlatFunds`,
`queryValues`, and the wizard/inspect/swap call sites). Only
`amaru-treasury-tx-api` reads UTxOs from its embedded indexer
(`Api.Server.indexerProvider`). On mainnet node 11.1.3 one address
query takes about 115 s; cardano-node-clients aborts a local-state
query after 60 s, so `disburse-wizard` fails with
`LocalStateQueryTimeout`.

## User story

US-1 — As a treasury operator, I set `--indexer-url URL` (or
`indexerUrl` in the config profile, or `AMARU_TREASURY_INDEXER_URL`)
and every UTxO read the CLI makes — by address, by several addresses,
by input — is answered by the treasury API's indexer, while protocol
parameters, evaluation, slot conversion and submission stay on the
local node.

## Requirements

- REQ-1 — `POST /v1/utxos` accepts `{"addresses":[bech32…]}` or
  `{"txins":["txid#ix"…]}` and answers
  `{"utxos":[{"txIn":"txid#ix","txOutCborHex":"…"}]}` from the
  server's indexer-backed provider. Malformed addresses or inputs
  answer 400. The existing lag guard answers 503 while lagging.
- REQ-2 — `txOutCborHex` is the Conway `TxOut` CBOR; decoding it
  yields the same `TxOut` (value, datum, reference script).
- REQ-3 — global `--indexer-url URL`, config `indexerUrl`, env
  `AMARU_TREASURY_INDEXER_URL`, with CLI > env > profile precedence.
- REQ-4 — with an indexer URL, the CLI provider's `queryUTxOs`,
  `queryUTxOByTxIn`, and the acquired handle's `queryUTxOsH`,
  `queryUTxOsAtH`, `queryUTxOByTxInH` go to `POST /v1/utxos`; every
  other provider field is the N2C provider's.
- REQ-5 — without an indexer URL, behaviour is unchanged.
- REQ-6 — a transport failure, non-200 status or undecodable entry
  throws; there is no fallback to N2C UTxO queries.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | request/response JSON and TxOut CBOR round-trip in unit tests | a field name, shape or CBOR encoding drifts |
| INV-2 | the wrapped provider, given a live provider whose UTxO fields throw, answers all five UTxO queries from the source | any UTxO query reaches the live provider |
| INV-3 | the wrapped provider forwards non-UTxO queries to the live provider | a non-UTxO query is answered by the source or dropped |
| INV-4 | the server endpoint answers by-address and by-input requests from the handler and 400 on a bad address | wrong route, shape or status |
| INV-5 | `--indexer-url`, `indexerUrl`, `AMARU_TREASURY_INDEXER_URL` resolve into `goIndexerUrl` with CLI > env > profile | a source is ignored or precedence differs |
| INV-6 | every CLI `withLocalNodeBackend` call site that receives `GlobalOpts` goes through the indexer-aware bracket | a CLI command still opens a bare N2C provider |

## Non-goals

- No change to the API's embedded indexer or lag threshold.
- No change to the cardano-node-clients 60 s timeout.
- Devnet harness binaries keep the bare N2C provider.
