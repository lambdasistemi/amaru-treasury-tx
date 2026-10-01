# functions model — #33

| ID | Function | Change |
|---|---|---|
| F-1 | `mkHash :: HashAlgorithm h => ByteString -> Either String (Hash h a)` in `Amaru.Treasury.IntentJSON.Common` | new, exported; expected length is the algorithm's digest size |
| F-2 | `mkHash28`, `mkHash32` (Common and DisburseIntentJSON) | removed |
| F-3 | parser signatures in M-1..M-3 | unchanged |
