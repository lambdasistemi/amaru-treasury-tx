# #215 plan — fix(disburse-wizard): USDM leftover

## Ownership split

- **Orchestrator (this PR's ticket-owner):** spec, plan, tasks,
  gate.sh, PR metadata, slice review, finalization commit. **Does
  not write production source or test code.**
- **Driver + Navigator pair (per slice S1):** writes the failing test
  RED, then the implementation fix GREEN, then commits one
  bisect-safe slice. Loaded with `pair-programming`.

The user's "no driver/navigator workers" instruction was for #202;
#215 is a different ticket (behavior-changing source fix) and should
follow the canonical pair-programming flow unless instructed
otherwise.

## Live-boundary diagnostic

Q: *What system boundary does this change exercise that the unit suite
cannot?*

A: **The on-chain Aiken-compiled treasury validator's lovelace-
conservation invariant** (`equal_plus_min_ada` in `disburse.ak`). The
current unit suite asserts the shape of the Haskell-produced
`TxBody`, but never runs the on-chain validator against that body.
The bug exists precisely in the gap between "Haskell tx body builder"
and "on-chain spending validator".

→ In-gate: a new Plutus-eval smoke test runs the on-chain disburse
   validator against a wizard-built USDM disburse tx and asserts
   accept. This closes the coverage hole that allowed the bug to ship.

→ Out-of-gate (operator follow-up): PR #213's T210 re-runs against
   the mainnet socket. Once #215 merges, the live build succeeds.

## Slice plan

### S1 — RED-then-GREEN slice (driver + navigator pair, one commit)

**RED phase** (in the same commit before the implementation edit):

- Rewrite
  `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs:282`
  (`"builds USDM beneficiary and treasury leftover values"`) so it
  asserts the validator-correct shape:

  ```haskell
  values `shouldBe`
    [ MaryValue (Coin <totalInputLovelace>) ⟨leftover USDM⟩
    , MaryValue (Coin 2_000_000)           ⟨beneficiary USDM⟩
    ]
  ```

  i.e., the treasury leftover output's lovelace equals the SUM of
  treasury input lovelace (not `sum − 2_000_000`).
- Add a new test under
  `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs` (or a sibling
  `DisburseValidatorSpec.hs`) that runs Plutus evaluation against the
  on-chain disburse validator for a wizard-built USDM disburse and
  asserts accept. Build the validator from
  `treasury-contracts/lib/logic/treasury/disburse.ak` (Aiken) or use
  `cardano-ledger-api` `evaluateTransactionExecutionUnits` against a
  fixture context.
- Confirm both tests FAIL against the current implementation.

**GREEN phase** (same commit):

- `lib/Amaru/Treasury/Tx/DisburseWizard.hs:515` — change
  `dtsLeftoverLovelace = totalLovelace - beneficiaryLovelace` to
  `dtsLeftoverLovelace = totalLovelace` for the USDM branch.
- `lib/Amaru/Treasury/Build/Disburse.hs:385` — change
  `usdmBeneficiaryLovelace` so the beneficiary's min-UTxO comes from
  the wallet UTxO selection (a new lovelace contribution from the
  wallet input above and beyond fee + change), not from the treasury
  input lovelace. The function may need a new argument for the
  wallet's available slack, or the tx-build pipeline may need a new
  step that adds the min-UTxO to the wallet's `walletFeeSlackLovelace`
  budget.
- Confirm both tests now PASS.
- Run `./gate.sh` (full `just ci`); expect green.

**Commit (bisect-safe, one slice):**

```
fix(disburse-wizard): USDM leftover keeps full treasury input lovelace

Closes #215.

The wizard previously subtracted the beneficiary's 2 M min-UTxO from
the treasury leftover and routed it to the beneficiary output,
violating the on-chain treasury validator's lovelace-conservation
rule (`equal_plus_min_ada` in disburse.ak) for any USDM disburse.

Fix:
* selectedToDisburseSelection: USDM leftover = full treasury input
  lovelace (no subtraction).
* usdmBeneficiaryLovelace: beneficiary min-UTxO sourced from wallet
  fuel, not from treasury inputs.

Adds a Plutus-eval smoke test against the on-chain disburse validator
that runs end-to-end and would have caught the original bug. Rewrites
`DisburseSpec.hs:282` which previously encoded the buggy lovelace
flow as expected behaviour.

Unblocks #202, #203, and all future wizard-built USDM disburses.

Tasks: T100, T110, T120, T130, T140, T150
```

### S2 — Finalization (orchestrator-owned)

- `git rm gate.sh` + `chore: drop gate.sh (ready for review)` commit.
- `gh pr ready`.

## Risks

- **`usdmBeneficiaryLovelace` plumbing.** The beneficiary's min-UTxO
  has to come from somewhere; routing it from the wallet UTxO may
  require changes to `selectWallet` (the slack parameter) or the
  tx-build output assembly. The driver may discover the cleanest seam
  is somewhere other than `usdmBeneficiaryLovelace`. The brief should
  not pre-commit to a specific seam; the constraint is "validator
  accepts and ADA disburse unchanged".
- **Min-UTxO is protocol-dependent.** `minUtxoDepositLovelace` is
  pinned at 2 M in `Constants.hs:110`; on Conway mainnet the real
  min-UTxO for a USDM output is closer to 1.5 M but can drift if the
  protocol parameters change. Keeping the 2 M constant is fine for
  now; flag if a future protocol change pushes it higher.
- **Devnet vs mainnet validator hashes.** The Plutus-eval smoke uses
  the SAME Aiken source, but compiled scope parameters differ. The
  test should parameterise on scope (or use a generic scope) so it's
  not network_compliance-specific.

## Carry-forward to siblings

- Once #215 merges to main, #197 rebases onto main and #202 (PR #213)
  rebases onto refreshed #197. T210 re-runs against the mainnet
  socket and succeeds.

## Plan-review checklist (orchestrator-self)

- [x] Connects to spec.md (P1 = the fix; tests + smoke = proof).
- [x] Names ownership split (orchestrator vs driver/navigator pair).
- [x] Identifies risks (above) and live-boundary diagnostic (above).
- [x] Defines proof strategy: rewritten unit test RED first,
      Plutus-eval smoke RED first, then GREEN in same commit.
- [x] One vertical bisect-safe slice (S1) + finalization (S2).
- [x] Live-boundary smoke included (Plutus eval against on-chain
      validator).
- [x] Deliverables enumerated; peer-surface check vacuous.
