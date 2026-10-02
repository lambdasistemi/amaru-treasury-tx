# tasks — #234 `vault relabel`

- [ ] T1 — RED: CI-run checks executing the real CLI for relabel
      (round trip + witness equality, old label rejected, payload
      preservation, work factor, in-place, wrong passphrase, rejection
      cases, cleartext scan, TTY path, help text, docs mention); fail
      on `main` 7a127220 (INV-1..INV-12).
- [ ] T2 — `vault relabel` parser, runner, pure payload relabel, work
      factor read (REQ-1..6).
- [ ] T3 — Operator docs list `vault relabel` (REQ-7, INV-11).
- [ ] T4 — `nix develop --quiet -c just ci` green; existing assertions
      untouched (INV-13).
