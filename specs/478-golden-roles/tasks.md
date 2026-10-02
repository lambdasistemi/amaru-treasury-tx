# tasks — #478 Stale report.golden.json fixtures

- [x] T1 — RED: default golden run regenerates each disburse/withdraw
      `report.golden.json` and compares byte-for-byte; fails on `main`
      on the stale disburse role (INV-3).
- [x] T2 — Regenerate disburse/withdraw `report.golden.json` and
      dependent `report.golden.md` with the real writer (INV-1, INV-2,
      INV-4).
- [x] T3 — Every tracked `report.golden.json` is covered by a
      regenerating comparison; `nix develop --quiet -c just ci` green;
      no production diff (INV-3, INV-5).
