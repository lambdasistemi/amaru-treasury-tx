# data model — #199

- D1 `DisburseRationaleJSON.drjDescription`,
  `DisburseRationaleJSON.drjJustification` : `Text` → `RationaleText`.
  Validation: JSON string or array of strings, else parse failure
  (REQ-4). State invariant: projection to `[Text]` preserves order and
  count (INV-1, INV-2).
