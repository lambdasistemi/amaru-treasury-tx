# tasks — #199 Disburse rationale multi-paragraph text

- [x] T1 — RED: unit test parsing a multi-paragraph disburse intent
      through the disburse JSON layer and observing every paragraph in
      the `RationaleBody`, plus scalar and round-trip cases; fails on
      base (INV-1, INV-2, INV-5).
- [x] T2 — Disburse rationale fields reuse `RationaleText`; translate
      via `rationaleTextLines`; wizard emits scalars (REQ-1..4, INV-4).
- [x] T3 — `nix develop --quiet -c just ci` green; goldens unchanged
      (INV-3, INV-6).
