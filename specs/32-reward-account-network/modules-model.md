# modules model — #32

| ID | Module | Change |
|---|---|---|
| M-1 | `Amaru.Treasury.IntentJSON` | `translateSwap` consumes the intent network for the permissions reward account; stops re-exporting `parseRewardAccount` |
| M-2 | `Amaru.Treasury.IntentJSON.Common` | loses `parseRewardAccount` (definition + export); `parseRewardAccountForNetwork` is the sole reward-account parser |

Dependency direction unchanged. See data-model.md / functions-model.md.
