# functions model — #32

| ID | Function | Change |
|---|---|---|
| F-1 | `parseRewardAccount :: Text -> Either String AccountAddress` | removed |
| F-2 | `translateSwap :: TreasuryIntent 'Swap -> Either String (TranslatedShared, SwapIntent)` | signature unchanged; reward-account network now from the intent |
