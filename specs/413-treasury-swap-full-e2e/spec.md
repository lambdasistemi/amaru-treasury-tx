# Spec — #413 Treasury swap e2e on devnet, FULL pipeline

> Deployed, spendable, devnet-re-rooted treasury that **funds its own
> SundaeSwap swap** via the shipped `swapProgram` (treasury debit +
> permissions withdraw-zero + 2-of-N owner signers), scooped against the
> fresh-cascade pool, with the treasury **receiving the swapped asset back**.

- **Issue:** https://github.com/lambdasistemi/amaru-treasury-tx/issues/413
- **Builds on:** #409 (PR #412, design A — derived-destination order, no deploy,
  no `swapProgram` debit). This branch is **stacked on** `409-treasury-swap-e2e`.
- **Feeds:** #396 (bot-validator wrapper — reuses a deployed spendable devnet
  treasury).

## P1 user story

As a treasury operator proving the full shipped swap path, I run **one** devnet
phase that deploys a real (devnet-rooted) treasury, funds it, builds a swap
order **out of treasury funds** via the production `swapProgram`, scoops it
against a real SundaeSwap V3 fresh-cascade pool, and ends with a machine-checkable
`summary.json` proving the treasury was debited for the swap and credited with
the swapped asset — so I trust the whole pipeline, not just an order whose
*destination* happens to be a treasury script.

## Why design A (#409) wasn't enough

#409 proves an order with a treasury-script **destination** fills. It uses a
**pure-derived** treasury (`treasuryTargetFromBlob … derivedTreasuryScriptBlob`),
pays for the order from the **genesis wallet**, and never deploys or spends a
treasury. The shipped path (`translateSwap` → `swapProgram`) instead **spends
deployed treasury UTxOs** to fund the order, withdraws-zero on the permissions
reward account, and requires owner signatures. #413 proves that.

## User stories

1. **Deploy + re-root.** The phase deploys the scopes/registry/permissions/
   treasury cascade re-rooted at a **devnet boot UTxO** (not the fixed mainnet
   seeds), producing on-chain reference scripts and a spendable treasury address.
2. **Fund.** The treasury is funded (governance withdrawal / genesis transfer)
   so it holds spendable ADA for the swap.
3. **swapProgram-funded order.** The order is built by the shipped `swapProgram`
   (`lib/Amaru/Treasury/Tx/Swap.hs`): spends treasury UTxOs, withdraws-zero on
   the permissions reward account, requires 2-of-N owner signers, emits the
   SundaeSwap order output(s) with the treasury as datum destination, and a
   leftover treasury output.
4. **Scoop.** The order is scooped against the fresh-cascade pool (reuse #409's
   `scoopTreasurySwapOrder`), routing the swapped asset to the treasury address.
5. **Assert + record.** `summary.json` records the proof (see success criteria).

## Functional requirements

- **FR1** New devnet phase `treasury-swap-full-e2e`, registered in the
  `test/devnet/.../SmokeSpec.hs` spec block and accepted by
  `scripts/smoke/devnet-local`, runnable via `DEVNET_SMOKE_PHASE=treasury-swap-full-e2e`.
- **FR2** Reuse the **disburse-submit deploy+fund scaffold**
  (`lib/Amaru/Treasury/Devnet/DisburseSubmit.hs` / `RegistryInit.hs`
  `deployDevnetWithdrawalRegistry`, `publishDevnetRegistryInit`,
  `deriveDevnetScripts`) to obtain a deployed, re-rooted, funded treasury with
  on-chain reference scripts and a permissions reward account.
- **FR3** Build the order via the **shipped** `swapProgram :: SwapIntent ->
  TxBuild q e ()`. The `SwapIntent` is assembled from the **deployed** anchors
  (`siScopesDeployedAt` / `siPermissionsDeployedAt` / `siTreasuryDeployedAt` /
  `siRegistryDeployedAt`), the funded treasury UTxOs (`siTreasuryUtxos`), the
  permissions reward account (`siPermissionsRewardAccount`), and owner signers
  (`siSigners`) that the harness can sign with (the genesis key).
- **FR4** Reuse #409's Sundae fresh-cascade pool bootstrap + `scoopTreasurySwapOrder`
  to scoop the order to the treasury address. **Real SundaeSwap V3 validators +
  real (devnet-rooted) treasury scripts** — no mocks.
- **FR5** Extend the evidence (`TreasurySwapEvidence` / `putTreasurySwapLines`)
  to also record the **treasury debit** (treasury ADA before/after; down by the
  swap amount + overhead), the **swapProgram order tx id**, and the **cascade +
  treasury (re-rooted) hashes + deploy anchors**.
- **FR6** Owner signers must satisfy the 2-of-N permissions policy with keys the
  harness holds (genesis key), so the order tx and the permissions withdraw-zero
  validate on chain.

## Success criteria (acceptance)

One devnet run produces `summary.json` (phase `treasury-swap-full-e2e`) with:

- `orderConsumed = true`
- `treasuryTokenQuantity > 0` (treasury received the swapped asset)
- treasury **debit** recorded: `treasuryAdaBefore - treasuryAdaAfter ==
  swapAmount + overhead` (treasury funded the swap)
- the `scoopTxId`, the **swapProgram order tx id**, and the cascade + treasury
  (re-rooted) hashes + deploy anchors
- `status = passed`

Plus: RED → GREEN, bisect-safe commits, `./gate.sh` green.

## Testing posture (live-boundary)

The e2e phase needs a **live devnet** (`E2E_GENESIS_DIR` + `SUNDAE_CONTRACTS_DIR`)
and — like #409's `treasury-swap-e2e` — is **not** part of `./gate.sh` / `just ci`
(unit + golden only). The live scoop is the **boundary smoke**: its proof is the
operator run that emits `summary.json`. RED → GREEN applies to the
**unit-testable** seams (e.g. `SwapIntent` assembly from deployed anchors, the
extended evidence schema/serialization); the on-chain scoop is proven by the
manual phase run. (See `live-boundary-smoke`.)

## Key design decisions (confirm at spec checkpoint)

- **D1 — Where the phase lives.** Add `treasurySwapFullE2ESmoke` in
  `test/devnet/.../SmokeSpec.hs` alongside #409's `treasurySwapE2ESmoke`,
  reusing the disburse-submit deploy+fund scaffold + #409's pool/scoop helpers.
  *(Recommended; keeps all devnet phases in one module.)*
- **D2 — How `swapProgram` is invoked.** Assemble `SwapIntent` **directly
  in-process** from the deployed anchors and call `swapProgram`, rather than
  round-tripping a `TreasuryIntent 'Swap` JSON through `translateSwap`. Calling
  `swapProgram` directly still exercises the real on-chain validators (treasury
  debit + permissions withdraw-zero + owner signers). *(Recommended. Alternative:
  also drive `translateSwap` from a JSON intent for max pipeline fidelity —
  higher cost, marginal extra coverage.)*
- **D3 — Gate scope.** `./gate.sh` / `just ci` stay unit + golden; the e2e phase
  is the manual live-boundary smoke. *(Matches #409.)*

## Out of scope

- The bot-validator wrapper itself (#396).
- Preview/mainnet live scoops.
- Driving `translateSwap` from JSON unless D2 alternative is chosen.
