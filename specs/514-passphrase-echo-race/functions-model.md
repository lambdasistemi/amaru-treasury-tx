# functions model — #514

| ID | Function | Change |
|---|---|---|
| F-1 | `readHiddenLine :: Text -> Fd -> Handle -> IO (Either Text BS.ByteString)` | signature unchanged; may be exported (from `Amaru.Treasury.Cli.Passphrase` or an `.Internal` module) for the unit suite |
| F-2 | `readVaultPassphrase`, `readVaultPassphraseConfirmed` | unchanged |
