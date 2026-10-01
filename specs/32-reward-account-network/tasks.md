# tasks — #32 Swap permissions reward account honours intent network

- [x] T1 — RED: unit test executing the swap translation on a
      non-mainnet swap intent, asserting a `Testnet` permissions
      reward account; fails on `main` (INV-1). Mainnet and
      unknown-network cases (INV-2, INV-4).
- [x] T2 — `translateSwap` uses the intent network for the
      permissions reward account (REQ-1, REQ-2).
- [x] T3 — Delete `parseRewardAccount` and its re-exports (REQ-3,
      INV-3).
- [x] T4 — `nix develop --quiet -c just ci` green; goldens unchanged
      (INV-2).
