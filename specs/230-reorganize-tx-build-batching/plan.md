# Plan — 230 reorganize tx-build auto-batching

## Trade-offs

- **Math vs bisection.** The math estimator (`N* = floor(N · sqrt(α
  · limit / total))`) is closed-form per iteration; bisection is
  `O(log N)` iterations. We pick math, with one or two refinement
  iterations as a safety net.
- **Picker in tx-build, not wizard.** The wizard stays a pure
  chain-fact gatherer; the picker needs the Plutus evaluator and
  `PParams` already wired into `tx-build`. No new coupling between
  the wizard and the evaluator.
- **Selection: largest-value first.** Maximizes consolidation yield
  per batch. Lovelace dominates the ordering; USDM is a follow-up
  knob.
- **No new CLI flags.** The picker is automatic. If the math chooses
  badly, the operator can re-run after the first batch settles
  (chain state will be smaller).

## Slice plan

### S1 — Math: pure scaler + unit tests

Smallest, isolated change. No build-path edits.

**Owned files:**

- `lib/Amaru/Treasury/Build/Reorganize/Batch.hs` (new) — pure module
  exporting:
  - `data BatchInputs = BatchInputs { biMeasuredCost :: ExUnits, biMeasuredSize :: Int, biCurrentN :: Int }`
  - `data BatchLimits = BatchLimits { blMaxExUnits :: ExUnits, blMaxSize :: Int, blSafetyAlpha :: Rational }`
  - `data BatchDecision = BatchKeep | BatchTruncateTo !Int`
  - `decideBatch :: BatchInputs -> BatchLimits -> BatchDecision` —
    the closed-form math.
  - `nStarFromMeasured :: Int -> ExUnits -> ExUnits -> Rational -> Int`
    — the core sqrt formula, exported for direct unit testing.
- `test/unit/Amaru/Treasury/Build/Reorganize/BatchSpec.hs` (new) —
  boundary cases for `decideBatch` / `nStarFromMeasured`.
- `amaru-treasury-tx.cabal` — register both new modules.

**RED → GREEN:**

- Test cases:
  - `total < limit` → `BatchKeep` (no truncation needed).
  - `total = 4 · limit`, N=55 → `N* ≤ floor(55 · sqrt(1/4)) = 27`.
  - `total = 22 · memLimit` (the real network_compliance number),
    N=55 → `N* ≤ floor(55 · sqrt(1/22)) ≈ 11` (mem-binding).
  - `total = 13 · stepsLimit` (the real network_compliance steps
    number), N=55 → `N* ≤ floor(55 · sqrt(1/13)) ≈ 15` (steps-binding).
  - Both bound — take the smaller (11).
  - Safety alpha = 0.85 — `N*` further shrinks by `sqrt(0.85)`.

### S2 — Wire the math into the build path

**Owned files:**

- `lib/Amaru/Treasury/Build/Reorganize.hs` — restructure
  `runReorganizeAction` into:
  1. `pickInputs` (new helper) — try building with the full set,
     measure, decide via `decideBatch`, recurse if truncated.
  2. `buildOnce` (extracted helper) — the existing build+align flow
     against a given input subset.
- `lib/Amaru/Treasury/Build/Result.hs` — add
  `brResidualTreasuryInputs :: ![TxIn]` (default `[]` when no
  truncation happened).
- `lib/Amaru/Treasury/Tx/Reorganize.hs` — no change. The
  `reorganizeProgram` already takes the input set as a parameter.

**RED → GREEN:**

- Existing unit tests in `test/unit/Amaru/Treasury/Build/Reorganize*`
  must remain green (full-set build still works on small treasuries).
- New build-path test with a synthetic `ChainContext` where the
  evaluator returns inflated exec units; assert the runner truncates
  and surfaces residue.

**Iteration cap:**

- `decideBatch` is called at most 3 times per `runReorganizeAction`
  call. After 3 iterations without convergence, the runner emits a
  typed `ReorganizeBatchUnconverged` error so the operator can
  re-run with hand-picked inputs.

### S3 — CLI residue surfacing

**Owned files:**

- `lib/Amaru/Treasury/Cli/TxBuild.hs` — print the residue
  (`reorganize: selected N of M UTxOs; residue: txid#ix, …`) on
  the existing tx-build trace stream.
- (Optional this slice) `--residue-out PATH` to emit a JSON list.
  Decide during implementation whether it's worth the extra
  surface in this PR or a follow-up.

### S4 — Live mainnet verification (orchestrator-owned)

Run the operator command on `network_compliance` against
`/code/cardano-mainnet/ipc/node.socket`. Archive `intent.json`,
`tx-build.log`, `reorganize.cbor.hex`, and the
`cardano-cli debug transaction view` output under
`evidence/230-mainnet/` (gitignored).

The PR body inlines:
- The trace line showing `selected N of M`.
- The tx-inspect / cardano-cli view output confirming
  asset preservation across the truncated set.
- The cbor hex blake2b digest.

**No merge** until the operator inspects this evidence and signs off.

### S5 — Finalize (gated on operator approval)

`./gate.sh` clean, `git rm gate.sh`, push, `gh pr ready 231`.
**Hold here until operator says merge.** Repeating the #218
unilateral-merge mistake is not acceptable.

## Live-boundary diagnostic

For S2 the unit tests prove the math. The acceptance is the
**live mainnet build on network_compliance** producing a submittable
tx body — that's the only proof that the math survives real-world
exec-unit shapes.

## Risks

- **`a` is large**, in which case the `cost ≈ k·N²` approximation
  picks `N*` too high and the rebuild still over-budget. Mitigation:
  the runner detects the second over-budget and falls back to
  `floor(N* · sqrt(limit / new_total))`, repeating up to the cap.
- **The wallet's funding-seed-txin doesn't have enough lovelace** to
  cover the per-tx fee × number of batches. Out of scope here —
  operator manages fuel UTxO refills between batches.
- **The largest-value-first ordering** might bias selection in a way
  that leaves a residue dominated by dust UTxOs; that's fine
  semantically (more cleanup is needed) and reflects the natural
  treasury topology.
- **Idempotence is observational, not enforced.** Re-running after
  a batch settles is the operator's job; we don't track on-chain
  state in this PR.

## Out of scope

- Submission.
- `--max-inputs N` flag.
- Wizard-side picker (stays in `tx-build`).
- Asset-preference ordering knob.
- Cross-scope batching.
