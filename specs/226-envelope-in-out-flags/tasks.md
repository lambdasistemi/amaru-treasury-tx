# tasks — #226 envelope `--in` / `--out`

- [x] T1 — RED: CI-run checks executing all four commands with
      `--in`/`--out` (and each alone) on the oracle fixtures, the
      `de-envelope --out` failure case, and `--help` flag text; fail
      on `main` (INV-1, INV-2, INV-4, INV-5, INV-6).
- [x] T2 — Parser options and IO runners for the four commands
      (REQ-1..5).
- [x] T3 — Operator docs mention the flags (REQ-6, INV-7).
- [x] T4 — `nix develop --quiet -c just ci` green; existing
      assertions untouched (INV-3).
