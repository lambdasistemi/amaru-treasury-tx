# 217 — reorganize-wizard UTxO selection: exclude script-deploy outputs

## Context

Issue: [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217)
Parent epic: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
Predecessor: [#212](https://github.com/lambdasistemi/amaru-treasury-tx/issues/212) — phase-2 scopes-NFT fix merged at `5bb75425`.
Successor: [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218) — mainnet path (depends on this fix).

After #212 lifted the permissions phase-2 error, `just devnet-cli-smoke
--phase reorganize` reaches phase-1 of the Conway ledger and fails:

```
ConwayUtxowFailure
  (UtxoFailure
    (BabbageNonDisjointRefInputs
       (TxIn "76d8750a..." (TxIx 0) :| [TxIn "76d8750a..." (TxIx 1)])))
```

The wizard-produced `intent.json` has the same outref appearing in
both `treasuryUtxos` (spend set) and `treasuryDeployedAt` /
`permissionsDeployedAt` (reference set). Conway requires reference
inputs to be **disjoint** from spent inputs.

## Root cause (evidence-backed)

Boundary helper `queryFlat`
(`lib/Amaru/Treasury/Cli/Common.hs:174-197`) summarizes each
`(TxIn, TxOut)` pair returned by `queryUTxOs` as
`(Text, Integer, Bool)` — outref text, lovelace, native-asset flag.
The summary **discards `referenceScript`** before any consumer can
read it.

The reorganize resolver
(`lib/Amaru/Treasury/Tx/ReorganizeWizard.hs:332-387`) then runs
`sortTreasuryUtxos`
(`lib/Amaru/Treasury/Tx/ReorganizeWizard.hs:396-433`), which only
enforces `length ≥ 2` and sorts by `TxIn`. **No filter excludes
script-deploy UTxOs.**

In the devnet bootstrap, the per-scope `treasury` and `permissions`
scripts are deployed to UTxOs **at the treasury script address** (the
two outputs of a single registry-init transaction at TxIx 0 and 1).
The address-scoped `queryUTxOs` then returns those script-deploy
UTxOs alongside real fund UTxOs, and `sortTreasuryUtxos` happily
picks them up. The wizard's intent ends up with the deploy UTxOs in
the spend set; the build phase also lists them as `reference` inputs
(via `rgiTreasuryDeployedAt` and `rgiPermissionsDeployedAt`); the
ledger rejects the tx at phase-1.

Upstream bash (`journal/2026/lib/select_treasury_utxos.sh` +
`is_blacklisted.sh` + `defaults.sh`) handles the same hazard via a
hand-maintained `BLACKLIST` array. That's a brittle pattern that
doesn't scale to per-scope per-network deploy outrefs. The Haskell
port should be structural.

## Owned-files surface

This PR touches:

- `lib/Amaru/Treasury/Cli/Common.hs` — add a sibling helper
  `queryFlatFunds` (or extend `queryFlat` with an explicit filter
  parameter) that drops UTxOs whose `referenceScript` is `SJust _`.
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` — wire
  `sreQueryTreasuryUtxos` to the new helper. Leave
  `sreQueryWalletUtxos` on the original `queryFlat` (wallet
  addresses don't carry reference scripts).
- `lib/Amaru/Treasury/Cli/SwapCommon.hs` — wire
  `reEnvQueryTreasuryUtxos` (`SwapCommon.hs:170`) to the new helper.
  The treasury swap path has the same latent bug.
- Disburse: separate audit (see Out of scope).

Test surface:

- `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` — RED + GREEN
  unit covering `resolveReorganize` rejecting / filtering a mocked
  treasury-UTxO list that includes the scope's `treasuryDeployedAt`
  outref.
- A focused unit on the new `queryFlatFunds` helper that feeds a
  mocked `Provider IO` (or pure value) with a mixed list and asserts
  the reference-script UTxOs are dropped.

## P1 user story

Operator runs the unchanged command:

```bash
nix develop -c just devnet-cli-smoke \
  --phase reorganize \
  --run-dir runs/devnet-cli/<stamp>
```

End-to-end: the wizard emits an intent without script-deploy outrefs
in `treasuryUtxos`; `tx-build --intent` builds a tx that passes
phase-1 and phase-2; the host signs + submits via the existing
pipeline; the merged treasury UTxO is confirmed on-chain.

## Acceptance criteria

1. `nix develop -c just ci` green.
2. RED unit test in
   `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` that fails
   on `origin/main` and passes at HEAD: given a mocked treasury-UTxO
   list including the scope's `treasuryDeployedAt` outref, the
   resolver excludes it from `riTreasuryUtxos`.
3. RED unit test for `queryFlatFunds` (or equivalent name) that
   covers the boundary filter.
4. **Live devnet smoke proof:** `nix develop -c just devnet-cli-smoke
   --phase reorganize --run-dir <stamp>` runs end-to-end, the
   reorganize tx submits, and the host confirms a merged treasury
   UTxO on-chain. Run dir archived in PR.
5. PR body cites a `tx-inspect` summary of the produced reorganize
   transaction body for evidence.
6. `gate.sh` passes before push.

## What this PR does NOT deliver

- **A mainnet reorganize transaction.** Lifting the
  `ReorganizeNonDevnetNetwork` guard and producing a real mainnet
  artifact is [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218).
  This PR enables #218 by removing the wizard's selection bug from
  the path.
- **A full audit of all wizards.** Only the reorganize + swap
  treasury queries are rewired. The disburse treasury path uses a
  different code shape (`MaryValue`-typed selection) and is audited
  in a follow-up if needed.

## Operator-doc impact

None for #188 (still gated on #218). The wizard CLI surface is
unchanged.
