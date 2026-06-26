# Plan — #413 treasury-swap-full-e2e

Design decisions locked at spec checkpoint: **D1** phase in `SmokeSpec.hs`;
**D2** direct `SwapIntent` assembly (no `translateSwap` JSON round-trip);
**D3** e2e stays a live-boundary smoke outside `gate.sh`.

## Tech stack / context

- Haskell, `GHC2021`, fourmolu 70-col, `-Werror`. Build/test via
  `nix develop -c just ci` (build + schema + unit + golden + format + hlint).
- Reused machinery (all verified in source):
  - `lib/Amaru/Treasury/Tx/Swap.hs` — `swapProgram :: SwapIntent -> TxBuild q e ()`,
    `SwapIntent(..)`, `SwapOrderOut(..)`, `SwapOrderDatumParams(..)`, `swapOrderDatum`.
  - `lib/Amaru/Treasury/Devnet/RegistryInit.hs` — `deployDevnetWithdrawalRegistry`,
    `publishDevnetRegistryInit`, `deriveDevnetScripts`; `DevnetRegistryAnchors(..)`
    (`draScopesRef`/`draPermissionsRef`/`draTreasuryRef`/`draRegistryRef`,
    `draPermissionsHash`, `draOwnerKeyHash`, `draTreasuryTarget`).
  - `lib/Amaru/Treasury/Devnet/DisburseSubmit.hs` — deploy+fund+spend scaffold
    template (`runDevnetDisburseSubmit`).
  - `test/devnet/.../SmokeSpec.hs` — #409's `treasurySwapE2ESmoke`, the Sundae
    fresh-cascade pool bootstrap, `placeTreasurySwapOrder`, `scoopTreasurySwapOrder`,
    `buildSubmitAndWait`, `TreasurySwapEvidence` (#409's, left untouched).

## Key insight

`SwapIntent`'s four `si*DeployedAt` fields, `siTreasuryAddress`,
`siPermissionsRewardAccount`, and `siSigners` are **exactly** what a deployed
`DevnetRegistryAnchors` exposes. So design B = *deploy+fund (disburse-submit
scaffold) → assemble a `SwapIntent` from the anchors + funded treasury UTxOs →
`swapProgram` → find the emitted order output → scoop it (#409) → assert treasury
credited + debited*. The order datum must carry the **fresh pool ident**
(`sodPoolId`) and the **re-rooted treasury hash** (`sodTreasuryScriptHash`), the
same way #409's `placeTreasurySwapOrder` does.

## Modules

- **New lib module** `lib/Amaru/Treasury/Devnet/SwapSubmit.hs` — the
  unit-testable seam:
  - `mkFullSwapIntent :: FullSwapInputs -> SwapIntent` — pure assembly mapping
    `DevnetRegistryAnchors` + funded treasury UTxOs + wallet fuel + pool ident +
    datum params + signers + slot onto `SwapIntent`. `siRedeemerAmountLovelace
    == sum siSwapOrders chunk lovelace`; `si*DeployedAt` from the anchors;
    `siTreasuryAddress = ttAddress (draTreasuryTarget …)`.
  - `TreasuryFullSwapEvidence(..)` + serialization (summary lines / JSON):
    extends #409's evidence with `tfseTreasuryAdaBefore`/`tfseTreasuryAdaAfter`
    (the debit), `tfseSwapOrderTxId` (the `swapProgram` tx), and the deploy
    anchors / re-rooted hashes (`tfseScopesRef`/`tfsePermissionsRef`/
    `tfseRegistryRef`/`tfsePermissionsHash`).
- **Devnet phase** `treasurySwapFullE2ESmoke` in `test/devnet/.../SmokeSpec.hs`.
- **Harness** `scripts/smoke/devnet-local` accepts `treasury-swap-full-e2e`.

## Slices (each one bisect-safe commit)

### Slice S1 — `SwapSubmit` lib seam (pure assembly + evidence schema)
- Add `lib/Amaru/Treasury/Devnet/SwapSubmit.hs` with `mkFullSwapIntent`,
  `FullSwapInputs`, `TreasuryFullSwapEvidence`, and its summary serialization.
- Expose the module + a `SwapSubmit` unit spec in `amaru-treasury-tx.cabal`.
- **RED:** `test/unit/Amaru/Treasury/Devnet/SwapSubmitSpec.hs` asserting:
  anchors → `si*DeployedAt` wiring; `siRedeemerAmountLovelace` = Σ chunks;
  `siTreasuryAddress` from the deployed target; `siSigners` satisfy 2-of-N;
  evidence serializes the debit + `swapProgram` tx id + anchors.
- **GREEN:** implement until the unit spec passes.
- **Gate:** `nix develop -c just ci` green.
- **Commit:** `feat(413): SwapSubmit lib seam — SwapIntent assembly + full-swap evidence`
  · `Tasks: T413-S1`

### Slice S2 — `treasury-swap-full-e2e` devnet phase (live-boundary)
- `treasurySwapFullE2ESmoke`: deploy+fund the re-rooted treasury (disburse-submit
  scaffold → `DevnetRegistryAnchors` + funded treasury UTxOs); assemble the
  `SwapIntent` via `mkFullSwapIntent`; submit the order with `swapProgram`
  (`buildSubmitAndWait`); locate the emitted order output as a `SundaeOrderUtxo`;
  reuse #409's pool bootstrap + `scoopTreasurySwapOrder`; populate
  `TreasuryFullSwapEvidence` (treasury before/after, `swapProgram` tx id, scoop
  tx id, anchors/hashes); write `summary.json`.
- Register the phase in the `SmokeSpec` spec block + `scripts/smoke/devnet-local`.
- **TDD exception (documented):** no unit harness for the live phase; proof is
  the phase run emitting `summary.json` with `orderConsumed=true`,
  `treasuryTokenQuantity>0`, treasury debited by `swapAmount+overhead`, the
  `swapProgram` order tx id + scoop tx id + re-rooted cascade/treasury hashes.
  Record the live signal in `WIP.md`.
- **Gate:** `nix develop -c just ci` green (build); then the live phase run:
  `E2E_GENESIS_DIR=… SUNDAE_CONTRACTS_DIR=… nix develop -c scripts/smoke/devnet-local --phase treasury-swap-full-e2e`.
- **Commit:** `feat(devnet): treasury-swap-full-e2e — deployed treasury funds swapProgram order, scooped`
  · `Tasks: T413-S2`

## Risks / watch-items

- **Order discovery after `swapProgram`:** the emitted order output must be
  wrapped as a `SundaeOrderUtxo` matching what `scoopTreasurySwapOrder` consumes
  (datum + value + pool ident). Mirror `placeTreasurySwapOrder`'s return shape.
- **2-of-N owners on devnet:** owner key hashes in `SwapOrderDatumParams` /
  `siSigners` must be keys the harness signs with (genesis-derived), else the
  permissions withdraw-zero / order cancel-policy won't validate.
- **Re-rooting:** treasury hash in the datum must be the **deployed** re-rooted
  hash (`draTreasuryTarget`), not #409's pure-derived mainnet-seed hash.
