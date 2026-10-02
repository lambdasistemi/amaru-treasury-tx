# modules model — #199

- M1 `Amaru.Treasury.IntentJSON` — owner of `RationaleText` and
  `rationaleTextLines`; exports them for reuse (no behaviour change).
- M2 `Amaru.Treasury.Tx.DisburseIntentJSON` — consumes M1's
  `RationaleText` for its rationale fields (D1); dependency direction
  unchanged (it already imports M1).
- M3 `Amaru.Treasury.Tx.DisburseWizard` — constructs D1 with scalar
  text (F2).
