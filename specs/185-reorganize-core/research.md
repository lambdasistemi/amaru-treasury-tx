# Research — `185-reorganize-core`

**Companion to**: [`plan.md`](./plan.md). Captures design decisions
that motivate the plan, alternatives considered, and rejected paths.

## 1. Why three slices, not one

**Decision:** S1 (typed shapes + intent-JSON roundtrip) → S2
(`Build.Reorganize` + golden) → S3 (dispatcher wire-up + end-to-end).

**Alternative considered:** one big "feat(tx): reorganize core" commit
touching all four files (`Tx/Reorganize.hs`, `IntentJSON.hs`,
`Build/Reorganize.hs`, `Build.hs`) + the fixture + the new specs +
the schema regen. Rejected because:

- A single ~600-line commit is hard to review by file and by
  intent. Reviewers cannot bisect cleanly.
- The proof shape RED→GREEN for the JSON roundtrip is unrelated to
  the RED→GREEN for the builder materialization; folding them masks
  what each test proves.
- Bisect-safety is preserved trivially: S1 leaves the dispatcher
  rejecting (existing test pattern), S2 adds a runner without
  wiring it (the new module is untested except by the new
  golden), S3 wires + replaces the test call.

**Alternative considered:** four slices, splitting "add JSON
instances" from "real record" and "phase-1 overflow proof" from
"add runner". Rejected because:

- The JSON instances and the real record are coupled — the
  instances reference the field names. Splitting them creates a
  commit with broken decoder.
- The phase-1 overflow proof (FR-015) is part of the runner's
  standard validation path; it has no test of its own outside the
  runner.

## 2. Why amend the field set (B2) vs. carry resolved totals (B1)

Resolved in Q-001 verdict B2; this section records *why* the flip
was the right call (the spec recorded the verdict but not the
deeper reasoning).

The wizard #187 implements **"compress until full"** iteration: it
starts with the full candidate UTxO set, builds the tx, and on
exec-units overflow drops one UTxO and retries. Three implications
for the library:

1. **Intent stability.** If the intent JSON carried `acc_lovelace`
   / `acc_usdm` totals, every iteration's intent would be different
   (the dropped UTxO's value falls out of the totals). The intent
   stops being a stable artifact the operator can sign or archive.
2. **Single source of truth.** With B2, the intent is just the
   candidate set of TxIns; the library recomputes totals from
   `ccUtxos`. The operator can re-derive the totals at any time by
   reading their wallet/treasury UTxO state.
3. **Avoids drift.** With B1, the intent and the chain could
   disagree (operator typed totals that don't match the UTxOs).
   The library would either trust the intent (and produce a tx that
   doesn't balance) or recompute and ignore the intent's totals
   (making the field cosmetic). B2 removes the ambiguity.

The peer pattern is `WithdrawIntent.wiRewardsAmount`, which DOES
carry a resolved total — but that's because the rewards balance is
queried separately from `ccUtxos` (it lives in the reward-account
state, not the UTxO set), so it has no `ccUtxos` source to
recompute from. Reorganize's totals come from `ccUtxos`, so the
recompute path is available and is the cleaner choice.

## 3. The `validateFinalPhase1` withdrawal path (FR-015 path)

Resolved by #191: `validateFinalPhase1` now seeds withdrawal reward
accounts and runs full ledger phase-1 validation for withdrawal-bearing
transactions, including exec-units overflow, so S2 does not add a
separate `ccEvaluateTx` side-path or a reorganize-specific diagnostic.

## 4. Choice of `MaryValue` vs. `(Coin, MultiAsset)` for the program signature

**Decision:** `reorganizeProgram :: ReorganizeIntent -> MaryValue -> TxBuild q e ()`.

`MaryValue` already wraps `(Coin, MultiAsset)`. The runner produces
a `MaryValue` by folding `ccUtxos` over `treasuryUtxos`; passing it
in directly avoids decomposing only to recompose inside `payTo`.

**Alternative considered:** `Coin -> MultiAsset -> TxBuild q e ()`.
Rejected because `payTo` takes a `MaryValue`, so the program would
just reconstruct it.

**Alternative considered:** compute the value inside the pure
program from `ChainContext` (passed as an argument). Rejected
because it couples the pure builder to the runner's `ChainContext`
type, which other pure programs (`disburseAdaProgram`,
`withdrawProgram`) deliberately do not touch.

## 5. NonEmpty handling at the parser layer

**Decision:** `ReorganizeInputs.treasuryUtxos :: NonEmpty TxIn`, with
a `FromJSON` instance that rejects empty arrays at the parser layer
with a typed error
(`fail "ReorganizeInputs.treasuryUtxos: empty array"`).
`translateIntent` re-checks defensively (a hand-crafted JSON could
bypass the `NonEmpty` invariant if the decoder used the wrong type
during testing).

**Alternative considered:** `[TxIn]` + check at translate time.
Rejected because the field is structurally `NonEmpty`; encoding the
invariant in the type is the cleaner option per the
[`haskell` skill] preferences.

## 6. Reorganize redeemer is byte-stable (no work to do)

`Amaru.Treasury.Redeemer.reorganizeRedeemer = Constr 0 []` is
already shipped and asserted byte-for-byte against
`make_redeemer_reorganize.sh`. No new redeemer work in this slice.

CBOR of `Constr 0 []` is `d87980` (single byte tag 121 = 0x79, empty
list 0x80 = `[]`). The golden's redeemer slot will contain this
exact byte sequence.

## 7. Existing `Tx.Withdraw` is the closest peer

Survey via `git grep -l 'Tx.Withdraw\|Build.Withdraw'` returned the
expected library + cabal files only (no release/CI/docs surfaces).
`Tx/Withdraw.hs` is ~99 lines, has the closest *shape* (one wallet
input + script-withdraw + one output + signers + validity bound) —
the only structural differences are:

1. Reorganize spends N treasury UTxOs via `spendScript` (Withdraw
   doesn't spend any treasury UTxO — it withdraws from the rewards
   account).
2. Reorganize's continuing-output value is computed from the spent
   treasury UTxOs (Withdraw's output is the rewards amount, which
   the runner queries separately).
3. Reorganize's signer is the scope owner (Withdraw doesn't require
   the scope-owner signature — Withdraw is permissionless on the
   validator's withdraw arm).

This means S2 starts from `Withdraw`'s scaffolding and replaces the
withdraw/output blocks with the N-input spend + sum-and-output
blocks.

## 8. Why no `Reorganize` entry in `SmokeSpec`

Q-001 side question. The `SmokeSpec` library-proof layer is a
DevNet-driven test that builds + submits transactions via the
library functions, asserting on-chain effects. Reorganize's smoke
parity lives in **#87** (the smoke slice). Adding a `Reorganize`
entry here would:

- couple `185-reorganize-core` to a DevNet harness it doesn't need
  for its proof,
- duplicate the smoke proof #87 will deliver more rigorously
  (including the `assert_execution_units` upstream-bash parity).

The library-proof for #185 is the **golden CBOR + round-trip**
combo; smoke parity is #87's job.

## 9. Diagnostic surface for exec-units overflow

**Decision:** reuse the existing final phase-1 diagnostic surface.
After #191, `validateFinalPhase1` covers withdrawal-bearing
transactions natively, so an exec-units overflow arrives through the
same `DiagnosticChecksFailed` / phase-1 failure path used by the
other action runners.

**Alternative considered:** add a new reorganize-specific
exec-units overflow variant to `BuildDiagnostic`. Rejected because
the new upstream reward-state path removed the need for a
reorganize-only side-path.

## 10. Multi-scope rejection (edge case)

Spec edge case: an intent whose `treasuryUtxos` reference multiple
distinct treasury addresses is structurally invalid. Two places to
enforce this:

- **At translate time** (S3) — `translateReorganize` projects each
  txin's output address from `ccUtxos` and asserts they're all
  equal to `treasuryAddress`. Typed `Left _`.
- **At runner time** (S2) — `runReorganizeAction` does the same
  projection and surfaces `missingUtxosError`-style failure.

**Decision:** at translate time (S3). The translate layer is where
shared invariants get enforced (rationale, signer resolution,
chain-context safety checks). The runner stays focused on the
build mechanics.

**Open if slice executor sees a problem:** if the address projection
requires fields not in `ChainContext` at the translate layer,
move the check to the runner. Either path is acceptable; the
review can flip it.

## 11. Same-TxIn-twice (edge case)

Decision: `translateReorganize` calls `NonEmpty.nub` on
`treasuryUtxos` before constructing the intent; if the result has
fewer elements than the input, the intent is rejected with
`Left "duplicate treasury UTxOs"`. This avoids surprising
double-spends at the build layer.

**Alternative considered:** silently dedupe. Rejected because it
hides operator mistakes.

## 12. Acceptance evidence trail

The full evidence trail from spec → tasks → commit → PR is captured
by the `Tasks:` trailer on each slice commit. The slice executor
brief includes the exact trailer required.

Per the `gate-script` skill, the trailer rides with the code in the
slice commit (amend on acceptance), never a separate "mark tasks
done" commit. The orchestrator (attx-185) is responsible for the
amend.
