# functions model — #522

- F1 `encodeUtxoEntry` / `decodeUtxoEntry` (REQ-2).
- F2 `answerUtxoQuery` — server-side request → response over a
  provider (REQ-1).
- F3 `withUtxoSource :: UtxoSource -> Provider IO -> Provider IO`
  (REQ-4).
- F4 `httpUtxoSource :: Text -> UtxoSource` over `POST /v1/utxos`
  (REQ-4, REQ-6).
- F5 `withCliBackend :: GlobalOpts -> FilePath -> (Provider IO -> IO a) -> IO a`
  (REQ-4, REQ-5).
