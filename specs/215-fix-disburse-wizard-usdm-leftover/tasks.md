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

- [ ] **T100** Driver: rewrite
      `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs:282` so it asserts
      the validator-correct shape (treasury leftover lovelace ==
      sum of treasury input lovelace; beneficiary lovelace == 2 M
      sourced from a separate wallet contribution). Add a comment
      naming Principle V (test-first) and the validator's
      `equal_plus_min_ada` rule. Confirm `cabal test
      unit:DisburseSpec` FAILS at this commit boundary.
- [ ] **T110** Driver: add a Plutus-eval smoke that runs the on-chain
      disburse validator against a wizard-built USDM disburse tx
      body and asserts ACCEPT. Either:
      (a) extend `DisburseSpec.hs` with a new
      `describe "validator acceptance" ...` block calling
      `evaluateTransactionExecutionUnits` (or the
      `cardano-ledger-api` equivalent) against a synthetic fixture
      that mirrors a `network_compliance` disburse, OR
      (b) add `test/unit/Amaru/Treasury/Tx/DisburseValidatorSpec.hs`
      housing the same logic. Pick the cleaner seam at brief time.
      Confirm the smoke FAILS at this commit boundary too.
- [ ] **T120** Navigator: RED review. Confirm both T100 and T110
      fail against unfixed implementation; veto if either is a
      tautology that passes against the buggy code.

### GREEN (same commit)

- [ ] **T130** Driver:
      `lib/Amaru/Treasury/Tx/DisburseWizard.hs:515` —
      USDM branch of `selectedToDisburseSelection` sets
      `dtsLeftoverLovelace = totalLovelace` (full treasury input
      lovelace). Leave the ADA branch untouched.
- [ ] **T140** Driver:
      `lib/Amaru/Treasury/Build/Disburse.hs:385` —
      `usdmBeneficiaryLovelace` sources the beneficiary output's
      min-UTxO from the wallet UTxO selection rather than from
      treasury inputs. The cleanest seam (`walletFeeSlackLovelace`,
      a new wallet-contribution argument, or restructured output
      assembly) is at driver discretion; navigator reviews. ADA
      disburse path is UNCHANGED.
- [ ] **T150** Driver: add a CHANGELOG.md Unreleased bullet
      referencing #215 and the bash-recipe parity restored.

### Verification (still inside the commit)

- [ ] **T160** Driver: confirm T100 + T110 both PASS against the
      fixed implementation. Run `./gate.sh`; expect green.
- [ ] **T170** Navigator: GREEN review. Confirm the diff matches the
      plan, no scope creep, ADA branch untouched. Sign off via
      STATUS.md `REVIEW-APPROVED green`.

### Commit + orchestrator review

- [ ] **T180** Driver: one commit total for S1. Subject:
      `fix(disburse-wizard): USDM leftover keeps full treasury input lovelace`.
      Body references #215 and ends with the trailer
      `Tasks: T100, T110, T120, T130, T140, T150, T160, T170, T180`.
- [ ] **T190** Orchestrator: rerun `./gate.sh` at HEAD; amend the
      slice commit with this `tasks.md` updated (checkboxes filled)
      per the resolve-ticket stamping rule; push.

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
