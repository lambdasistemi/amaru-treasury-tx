# tasks — #33 Typed errors for byte → hash conversion

- [ ] T1 — RED: unit properties for F-1 (INV-1, INV-2) and
      parser-level wrong-length examples (INV-3).
- [ ] T2 — Total F-1 in `IntentJSON.Common`; partial helpers removed;
      every `lib/` call site threads the `Left` (REQ-1, REQ-2, INV-4).
- [ ] T3 — `DisburseIntentJSON` duplicates deleted in favour of F-1
      (REQ-3, INV-4).
- [ ] T4 — Devnet constant helper total (REQ-4, INV-4).
- [ ] T5 — `nix develop --quiet -c just ci` green; goldens and
      schemas byte-identical (REQ-5, INV-5).
