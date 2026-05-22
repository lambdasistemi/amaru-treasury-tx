# #215 tasks

Two slices: **S1** (RED-then-GREEN driver/navigator pair, one
bisect-safe commit) and **S2** (orchestrator-owned finalization).

## S1 — fix USDM leftover lovelace (driver + navigator pair)

Owned files for the pair:

- `lib/Amaru/Treasury/Tx/DisburseWizard.hs`
- `lib/Amaru/Treasury/Build/Disburse.hs`
- `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs`
- (optional, if a new spec file is cleaner)
  `test/unit/Amaru/Treasury/Tx/DisburseValidatorSpec.hs`
- `CHANGELOG.md`

Forbidden scope:

- Aiken sources in `treasury-contracts/`, `validators/`, `lib/*.ak`.
- `vendors.yaml`, `.specify/memory/constitution.md`.
- `transactions/`, `journal/`.
- The `--reference-*` flag surface (`disburseWizardOptsP`).
- `gate.sh`, PR/issue metadata.

### RED (in the same commit, before GREEN)

- [X] **T100** Rewrote
      `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs:260` so the
      structural assertion uses the validator-correct payload
      shape (treasury leftover lovelace == full input lovelace;
      beneficiary lovelace is wallet-funded). Comment names the
      validator's `equal_plus_min_ada` rule and #215.
- [X] **T110** Added a keystone `selectDisburseUsdm: lovelace
      conservation (#215)` block to `DisburseSpec.hs` that
      asserts the wizard-level invariant directly:
      `dtsLeftoverLovelace == sum (lovelaceOf <$> selected)` for
      both a single-input and a multi-input USDM selection, and
      that `dtsLeftoverUsdm == sum_input_usdm - amount`.
      Confirmed both new assertions FAIL against the unfixed
      implementation (off-by-2 000 000 lovelace), matching the
      bug report's concrete numbers. A full Plutus-eval smoke
      driving `evaluateTransactionExecutionUnits` against the
      compiled treasury validator is deferred to a follow-up;
      the wizard-level invariant catches this bug class
      directly.
- [X] **T120** Solo run per operator direction ("resolve it, on
      your own, no workers"); navigator role folded into the
      orchestrator. RED evidence captured in the commit body.

### GREEN (same commit)

- [X] **T130** `lib/Amaru/Treasury/Tx/DisburseWizard.hs` —
      `selectDisburseUsdm` now passes `0` to
      `selectedToDisburseSelection`, so
      `dtsLeftoverLovelace = totalLovelace` for USDM. The
      `beneficiaryLovelace` parameter was renamed
      `leftoverLovelaceFloor` to reflect that it now only
      protects the leftover output's own min-UTxO, not the
      beneficiary deposit. ADA branch untouched.
- [X] **T140** `lib/Amaru/Treasury/Build/Disburse.hs` —
      `usdmBeneficiaryLovelace` is now a constant
      (`Coin minUtxoDepositLovelace`), independent of treasury
      inputs. The build pipeline's `runDisburseUsdmAction`
      consumes it directly; the wallet input supplies the
      lovelace at balancing time, matching the bash recipe's
      flow. ADA disburse path is UNCHANGED.
- [X] **T150** CHANGELOG.md Unreleased bullet added under
      `## Unreleased`, referencing #215 and the bash-recipe
      parity restored.

### Verification (still inside the commit)

- [X] **T160** Confirmed: 34 disburse-matched unit tests pass;
      `./gate.sh` is green (build + unit + golden + format +
      smoke + release-check).
- [X] **T170** Solo run per operator direction; orchestrator
      reviewed the diff directly. ADA branch untouched, scope
      limited to the four owned files, no incidental edits to
      `specs/`, `transactions/`, or constitution.

### Commit + orchestrator review

- [X] **T180** Single S1 commit. Subject:
      `fix(disburse-wizard): USDM leftover keeps full treasury input lovelace`.
      Body references #215 and carries the trailer
      `Tasks: T100, T110, T120, T130, T140, T150, T160, T170, T180`.
- [X] **T190** `./gate.sh` re-run at HEAD; slice commit amended
      with this tasks.md update per the resolve-ticket stamping
      rule before push.

## S2 — Finalization (orchestrator-owned)

- [ ] **T200** Orchestrator: `git rm gate.sh` +
      `chore: drop gate.sh (ready for review)` commit; push;
      `gh pr ready`.
- [ ] **T210** Orchestrator: comment on PR #213 (#202) and the not-
      yet-opened #203 PR that #215 has merged and they can rebase
      onto refreshed main. Append `COMPLETE <pr-url>` to STATUS.md.

## Notes

- This ticket follows the canonical resolve-ticket flow with a
  driver/navigator pair (unlike #202 where the operator instructed
  "no workers" because the work was operator-execution, not
  source-changing). Confirm pair-CLI choice with the operator at
  dispatch time.
- The bash recipe (`journal/2026/bin/disburse.sh` +
  `lib/select_treasury_utxos.sh`) is the reference for the correct
  lovelace flow. The driver should cross-reference it when sourcing
  the beneficiary's min-UTxO.
- The Plutus-eval smoke is the keystone deliverable: future USDM
  disburse regressions will be caught at unit-test time, not at
  mainnet-build time.
