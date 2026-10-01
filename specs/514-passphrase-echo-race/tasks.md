# tasks — #514 Vault passphrase prompt echo race

- [x] T1 — RED: unit test driving the real hidden read under a
      pseudo-terminal; fails on `main` deterministically (INV-1,
      INV-2, INV-3), plus attribute restore on every exit path
      (INV-4).
- [x] T2 — Hidden read clears echo before the prompt and restores
      attributes on every exit path (REQ-1, REQ-2).
- [x] T3 — `nix develop --quiet -c just ci` green; smoke script
      untouched; goldens unchanged (INV-5, INV-6).
