# #215 — fix(disburse-wizard): USDM leftover mis-allocates 2 M lovelace

Full bug context, root-cause analysis, and acceptance criteria live in
[issue #215](https://github.com/lambdasistemi/amaru-treasury-tx/issues/215).
This spec.md mirrors the issue at the moment of branch creation; the
issue is the source of truth.

## P1 user story

As the Amaru treasury operator I need every USDM `disburse-wizard`
invocation to produce a tx body that the on-chain treasury validator
accepts on phase-2 evaluation. Today, **every USDM disburse the wizard
produces is rejected** because the wizard subtracts the beneficiary's
2 M min-UTxO lovelace from the treasury leftover output, violating the
validator's `equal_plus_min_ada` rule
(`treasury-contracts/lib/logic/treasury/disburse.ak:32`).

## Acceptance criteria

### Implementation

- [ ] `lib/Amaru/Treasury/Tx/DisburseWizard.hs` —
      `selectedToDisburseSelection` no longer subtracts
      `beneficiaryLovelace` from `dtsLeftoverLovelace` for USDM
      disburses. Treasury leftover lovelace == sum of selected
      treasury input lovelace.
- [ ] `lib/Amaru/Treasury/Build/Disburse.hs` —
      `usdmBeneficiaryLovelace` sources the beneficiary output's
      min-UTxO from the wallet UTxO selection, not from the treasury
      inputs.
- [ ] ADA disburse path (`selectDisburseAda` / ADA branch of
      `usdmBeneficiaryLovelace`) is UNCHANGED. For ADA the redeemer's
      `amount.lov > 0`, the validator's check becomes
      `leftover.lov ≥ input.lov − amount.lov`, and the existing
      `leftover = input − amount` math is correct.

### Tests

- [ ] `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs:282`
      (`"builds USDM beneficiary and treasury leftover values"`)
      rewritten to assert the validator-correct shape: treasury
      leftover output's lovelace == sum of treasury input lovelace;
      beneficiary output's lovelace sourced from a separate (wallet)
      contribution. The rewritten test MUST fail against the current
      (unfixed) implementation and pass against the fixed one.
- [ ] A new test (or extension of an existing spec) runs Plutus
      evaluation against the on-chain disburse validator for a
      wizard-built USDM disburse tx body and asserts the validator
      accepts. This is the test that, had it existed, would have
      caught the bug. Implementation: either Haskell-side
      (`cardano-ledger-api` `evaluateTransactionExecutionUnits` against
      a hard-coded `network_compliance` scope fixture), or an Aiken
      `aiken test` against the disburse logic with a synthetic
      transaction fixture.

### Live-boundary proof

- [ ] After this PR merges, re-run PR #213's T210
      (`./scripts/build-may-cc-disburse.sh --exec ...` against the
      mainnet socket). `tx-build` completes successfully (no
      `script evaluation failed`); the produced `tx.cbor` passes
      `tx-inspect --rules amaru-treasury.yaml` clean.

## Exclusions / non-goals

- No changes to `disburse.ak` or any Aiken source — the on-chain
  validator is the source of truth.
- No changes to `vendors.yaml`, `.specify/memory/constitution.md`,
  `transactions/`, `journal/`, or anything under
  `pragma-org/amaru-treasury`.
- No changes to the `--reference-*` flag surface (#196 / #197).
- No new operator command or CLI flag.

## Deliverables

| Artifact | Surface |
|---|---|
| `lib/Amaru/Treasury/Tx/DisburseWizard.hs` (fix) | Compiled into `amaru-treasury-tx`. |
| `lib/Amaru/Treasury/Build/Disburse.hs` (fix) | Same. |
| `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs` (rewrite) | Unit suite. |
| New Plutus-eval smoke test | Coverage hole closer. |
| `CHANGELOG.md` Unreleased bullet | Release notes. |

No new executable, no docs surface, no asciinema cast. Peer-surface
check is vacuous (the change is internal to an existing executable
that already ships everywhere).

## Constitutional alignment

- **Principle V (test-first with golden CBOR fixtures — NON-NEGOTIABLE)** —
  the rewritten unit test is RED first (fails on current impl) before
  the implementation fix lands.
- **Principle I (faithful port of bash recipes)** — the fix moves the
  wizard's lovelace flow toward the bash recipe's shape
  (`leftover_treasury_lovelace = acc_lovelace`; beneficiary's
  min-UTxO from wallet fuel).

## Non-claims

- This PR does NOT change the rationale CBOR shape. The d6c14625
  golden continues to pass without modification.
- This PR does NOT change the ADA disburse path. ADA disburses were
  not broken.
- This PR does NOT submit any mainnet transaction. PR #213 is the
  consumer that will exercise the fix end-to-end on mainnet, on
  explicit operator go.
