# Tasks — #413 treasury-swap-full-e2e

One commit per slice. Each task box flips to `[X]` (with the commit SHA) in the
same amended commit that lands the slice.

## Slice S1 — `SwapSubmit` lib seam (pure assembly + evidence schema)

- [ ] T413-S1-a RED: `test/unit/Amaru/Treasury/Devnet/SwapSubmitSpec.hs` —
      `mkFullSwapIntent` maps `DevnetRegistryAnchors` → `si*DeployedAt`;
      `siRedeemerAmountLovelace` = Σ chunk lovelace; `siTreasuryAddress` from
      `draTreasuryTarget`; `siSigners` satisfy 2-of-N; `TreasuryFullSwapEvidence`
      serializes the treasury debit + `swapProgram` tx id + deploy anchors.
- [ ] T413-S1-b GREEN: `lib/Amaru/Treasury/Devnet/SwapSubmit.hs` —
      `FullSwapInputs`, `mkFullSwapIntent`, `TreasuryFullSwapEvidence`,
      summary serialization.
- [ ] T413-S1-c Expose module + unit spec in `amaru-treasury-tx.cabal`.
- [ ] T413-S1-d Gate: `nix develop -c just ci` green; fourmolu + hlint clean.
- [ ] T413-S1-e Commit:
      `feat(413): SwapSubmit lib seam — SwapIntent assembly + full-swap evidence`
      (`Tasks: T413-S1`).

## Slice S2 — `treasury-swap-full-e2e` devnet phase (live-boundary)

- [ ] T413-S2-a `treasurySwapFullE2ESmoke` in `test/devnet/.../SmokeSpec.hs`:
      deploy+fund re-rooted treasury (disburse-submit scaffold → anchors +
      funded treasury UTxOs).
- [ ] T413-S2-b Assemble `SwapIntent` via `mkFullSwapIntent`; submit the order
      with `swapProgram` (`buildSubmitAndWait`); capture the `swapProgram` tx id.
- [ ] T413-S2-c Locate the emitted order output as a `SundaeOrderUtxo`; reuse
      #409 pool bootstrap + `scoopTreasurySwapOrder` to scoop to the treasury.
- [ ] T413-S2-d Populate + write `TreasuryFullSwapEvidence` → `summary.json`
      (treasury before/after, `swapProgram` tx id, scoop tx id, anchors/hashes).
- [ ] T413-S2-e Register phase in the `SmokeSpec` spec block +
      `scripts/smoke/devnet-local`.
- [ ] T413-S2-f Gate: `nix develop -c just ci` green (build).
- [ ] T413-S2-g Live-boundary proof (documented TDD exception): run
      `E2E_GENESIS_DIR=… SUNDAE_CONTRACTS_DIR=… nix develop -c scripts/smoke/devnet-local --phase treasury-swap-full-e2e`;
      record in `WIP.md`: `orderConsumed=true`, `treasuryTokenQuantity>0`,
      treasury debited by `swapAmount+overhead`, the order + scoop tx ids.
- [ ] T413-S2-h Commit:
      `feat(devnet): treasury-swap-full-e2e — deployed treasury funds swapProgram order, scooped`
      (`Tasks: T413-S2`).
