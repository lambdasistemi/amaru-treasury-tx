# data model — #478

- D1 — a report fixture: fixture input dir (intent + frozen chain
  context) ↦ committed `report.golden.json` (+ dependent
  `report.golden.md`). Invariant: committed bytes = writer(inputs)
  (INV-2).
- D2 — the extent: all `git ls-files '*report.golden.json'`; each must
  map to exactly one regenerating comparison (INV-3).
