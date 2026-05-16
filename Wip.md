# WIP: DevNet Treasury Action Proofs

Date: 2026-05-16
Branch: `140-devnet-disburse`
PR: #145
Issue: #86

## Current Status

This branch is paused after discovering that #86 was proving only an
unsigned disburse build, not a submitted treasury action.

PR #145 has been put back into draft. This checkpoint is being pushed as
a WIP commit on the PR branch even though the exploratory code may not
compile as-is.

## User Direction

Each DevNet slice must prove one treasury transaction action works on
DevNet. "Works" means the action is submitted and chain state verifies
the effect.

The smoke/spec layer may call code directly as an opportunistic layer,
but it must not become the owner of reusable setup or treasury-action
transaction construction. The code behind setup and operator-owned
actions belongs in production modules/commands. Actions performed by
other roles, such as a later swap sweep, can remain modeled as external
role interactions in the DevNet proof.

## What Was Learned

- ADA was materialized at the DevNet treasury spending validator.
- The disburse builder can construct an unsigned transaction spending
  that treasury UTxO.
- Submitting that transaction exposed missing production prerequisites:
  the permissions zero-withdrawal path must be Testnet-aware and the
  permissions reward/stake setup must exist on DevNet.
- `translateDisburse` currently needed the same network-aware reward
  account parsing that withdrawal already uses.
- Adding more bootstrap transaction logic directly inside
  `SmokeSpec.hs` is the wrong direction. That effort should be recovered
  into production-facing DevNet/bootstrap/action modules or CLI
  surfaces, then the smoke should drive those surfaces and assert chain
  effects.

## Local WIP Contents

The local diff currently contains:

- A RED/GREEN diagnostic contract requiring disburse submission/effect
  fields in the summary.
- A distinct DevNet beneficiary address so beneficiary receipt is not
  conflated with wallet change.
- An exploratory `signSubmitAndVerifyDisburse` path in
  `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- A network-aware `translateDisburse` reward-account parser change in
  `lib/Amaru/Treasury/IntentJSON.hs`.
- Partial, interrupted changes toward governance-funding extra reward
  accounts. This local WIP may not compile as-is.

## Recovery Plan

1. Move reusable DevNet system initialization code out of
   `SmokeSpec.hs` into production code.
2. Expose production-backed commands or reusable modules for:
   registry/script publication, required staking/reward setup,
   governance withdrawal materialization, and disburse submit.
3. Keep the smoke spec thin: invoke the production layer, then query the
   local chain to verify submitted tx id, treasury debit, and beneficiary
   receipt.
4. Keep `translateDisburse` network-aware for reward accounts, with unit
   coverage for `devnet`/testnet disburse translation.
5. Resume #86 only after the proof is a submitted DevNet treasury
   disburse, not merely an unsigned tx build.

## Verification Evidence So Far

- RED was observed for the new submitted-summary contract:
  `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='disburse diagnostics'`
  failed because the summary lacked submitted/effect fields.
- The focused diagnostics test later passed after adding the summary
  contract plumbing.
- Live `just devnet-smoke disburse` still failed on submission/setup
  prerequisites. Do not treat the current WIP as complete.
