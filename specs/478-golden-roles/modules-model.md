# modules model — #478

- M1 — the golden test suite (`test/golden/`) owns comparing every
  tracked `report.golden.json` with a regeneration by the real build +
  report writer (`runFromIntent`, `buildTransactionReport`,
  `encodeBuildOutput`). Dependency direction: test → lib only.
- No production module changes (INV-5).
