# functions model — #234

- F1 relabel options parser (REQ-1..3, REQ-5, INV-10).
- F2 `runVaultRelabel :: GlobalOpts -> VaultRelabelOpts -> IO ()` (REQ-1..6).
- F3 pure payload relabel: `ByteString` (decrypted v1 payload), optional
  selector, new label → `Either` D2/`VaultError` `ByteString` (INV-3, INV-7).
- F4 input work factor of an age ciphertext → `Either AgeVaultError WorkFactor` (INV-4).
