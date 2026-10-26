# data model — #522

- D1 `UtxoQueryRequest` — `UtxoQueryByAddresses [Text]` |
  `UtxoQueryByTxIns [Text]`; JSON `{"addresses":[…]}` / `{"txins":[…]}`.
- D2 `UtxoQueryEntry` — `{ txIn :: Text, txOutCborHex :: Text }`.
- D3 `UtxoQueryResponse` — `{ utxos :: [UtxoQueryEntry] }`.
- D4 `UtxoSource` — by-addresses and by-inputs lookups in `IO`.
- D5 `goIndexerUrl :: Maybe Text` on `GlobalOpts`; `indexerUrl` on the
  profile, overrides and resolved config.
