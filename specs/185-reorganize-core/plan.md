# Implementation Plan — `185-reorganize-core`

**Feature Branch**: `185-reorganize-core`
**Created**: 2026-05-21
**Status**: Draft (Plan phase)
**GitHub Issue**: [#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
**Spec**: [`spec.md`](./spec.md) — Q-001 resolved (A1 / B2 / C1).
**Companion artifacts**:
- [`research.md`](./research.md) — design decisions, alternatives, rejected paths.
- [`data-model.md`](./data-model.md) — typed shapes, JSON shape, error variants.
- [`contracts/`](./contracts/) — dispatcher contract, intent-schema delta, fixture layout.

> This is the **library core** slice (epic #189 child 1 of 5). It
> produces no operator-facing command and no CLI parser change. The
> shipped surface that changes is the **library + `tx-build --intent`
> dispatch arm** (the parser is unchanged; the dispatcher's
> `SReorganize` branch starts emitting real bytes instead of an
> `UnsupportedAction` error). Sibling children #186/#187/#87/#188
> are blocked on this slice.

## Ownership split

| Role | Owns |
|---|---|
| Orchestrator (attx-185) | `spec.md`, `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `contracts/`, `gate.sh`, PR metadata, slice briefs, vertical-slice review, finalization audit, post-merge cleanup. |
| Slice executor (one per slice, paired driver+navigator if requested) | Owned files listed per slice below; produces exactly one bisect-safe commit per run with a `Tasks:` trailer. Does not push. |

## Vertical slice plan (bisect-safe)

The work decomposes into **three slices** (the brief's suggestion).
Each slice is one paired-worker run producing exactly one commit.
Every commit compiles, every commit's `./gate.sh` is green at HEAD.

### S1 — typed shapes + intent-JSON roundtrip (RED → GREEN)

**Goal:** replace both placeholder shapes (`ReorganizeIntent` in
`Tx/Reorganize.hs`, `ReorganizeInputs` in `IntentJSON.hs`) with real
records carrying the Q-001 A1/B2/C1 field set. Add the intent-JSON
encode/decode wiring for `ReorganizeInputs` and the round-trip golden.
Regenerate `docs/assets/intent-schema.json`. `translateIntent` and
the `Build` dispatcher arm still return their existing "not yet
shipped" / `UnsupportedAction` errors at end-of-slice.

**Owned files (S1 only):**

- `lib/Amaru/Treasury/Tx/Reorganize.hs` — replace placeholder
  `data ReorganizeIntent = ReorganizeIntent` with the real record
  (Q-001 A1 + B2 field set; see [`data-model.md`](./data-model.md) §1).
- `lib/Amaru/Treasury/IntentJSON.hs` — replace placeholder
  `ReorganizeInputs` (lines 540–548) with the real record + its
  `FromJSON` / `ToJSON` instances. **Do not** touch `translateIntent`
  (still returns the stub `Left` until S3).
- `lib/Amaru/Treasury/IntentJSON/Schema.hs` (or wherever the
  `amaru-treasury-intent-schema` exe writes from — slice executor
  greps to confirm) — update the `Reorganize` schema arm.
- `docs/assets/intent-schema.json` — regen via
  `cabal run -v0 -O0 exe:amaru-treasury-intent-schema > docs/assets/intent-schema.json`.
- `amaru-treasury-tx.cabal` — only if a new module is exposed by
  this slice (likely no change; the new module
  `Amaru.Treasury.Build.Reorganize` lands in S2).
- `test/unit/Amaru/Treasury/IntentJSONSpec.hs` — extend the
  `intentRoundtrip` table-driven property with a `Reorganize`
  generator + assertion (mirrors `genGovernanceWithdrawalInitProposalIntent`
  shape at lines 522–544).

**RED:** add the `Reorganize` generator entry to `IntentJSONSpec`
first; the run fails because either:
- the placeholder record decoder doesn't accept the new fields, or
- the generator references record fields the placeholder doesn't
  expose.

**GREEN:** replace both record declarations with their real shapes;
wire encode/decode; regenerate the schema; the round-trip property
flips green.

**Gate evidence for S1:**

- `nix develop --quiet -c just unit --match "IntentJSON"` passes.
- `nix develop --quiet -c just schema-check` passes (regenerated
  schema matches the committed file).
- `./gate.sh` passes.

**Commit subject:** `feat(intent): real ReorganizeInputs + ReorganizeIntent shapes`

---

### S2 — `Build.Reorganize` runner + builder materialization golden (RED → GREEN)

**Goal:** add the new module
`Amaru.Treasury.Build.Reorganize` exposing
`runReorganizeBuild` + `runReorganizeAction` + the pure
`reorganizeProgram :: ReorganizeIntent -> MaryValue -> TxBuild q e ()`.
Add a builder materialization golden under `test/fixtures/reorganize-core/synthetic/`
mirroring `test/fixtures/withdraw/synthetic/`. The dispatcher arm
in `Amaru.Treasury.Build` is **not** yet wired (S3 wires it); the
golden test calls `runReorganizeBuild` directly with a fixture
`ReorganizeIntent` so the slice is bisect-safe.

**Owned files (S2 only):**

- `lib/Amaru/Treasury/Tx/Reorganize.hs` — add `reorganizeProgram`
  (pure `TxBuild` program; see
  [`contracts/reorganize-program-contract.md`](./contracts/reorganize-program-contract.md)).
- `lib/Amaru/Treasury/Build/Reorganize.hs` — new module:
  `runReorganizeBuild`, `runReorganizeAction`, the
  preserved-value fold helper, and the typed exec-units check
  (FR-015; see [`research.md`](./research.md) §3).
- `lib/Amaru/Treasury/Build/Error/Types.hs` — add the
  `DiagnosticExecUnitsExceeded { used :: ExUnits, max :: ExUnits }`
  variant to `BuildDiagnostic` (decision recorded in research).
- `lib/Amaru/Treasury/Build/Error/Render.hs` — render the new
  variant.
- `amaru-treasury-tx.cabal` — expose
  `Amaru.Treasury.Build.Reorganize` in the `library` stanza.
- `test/fixtures/reorganize-core/synthetic/` — new fixture dir:
  `answers.json`, `env.json`, `expected.cbor`, `exunits.json`,
  `intent.json`, `pparams.json`, `provenance.md`, `utxos.json`
  (mirrors the withdraw fixture layout).
- `test/golden/ReorganizeGoldenSpec.hs` — new golden harness
  calling `runReorganizeBuild` (not `runFromIntent` yet — that's
  S3). Pattern: mirror `WithdrawGoldenSpec.hs`.
- `test/golden/Spec.hs` — register the new spec.

**RED:** create the empty fixture dir + the new `ReorganizeGoldenSpec`
referencing an `expected.cbor` that doesn't exist yet. The
materialization test fails because:
- the module `Amaru.Treasury.Build.Reorganize` does not exist
  (compile-time RED), then
- `expected.cbor` is missing (test-time RED).

**GREEN:** implement `reorganizeProgram` + runner; run the
golden harness with `UPDATE_GOLDENS=1` to write `expected.cbor`;
re-run without the flag to confirm byte-stable.

**Gate evidence for S2:**

- `nix develop --quiet -c just unit --match "Reorganize"` passes.
- `nix develop --quiet -c just golden --match "reorganize"` passes
  (or `just golden` if `--match` is not plumbed for golden).
- `./gate.sh` passes.

**Commit subject:** `feat(tx): add Build.Reorganize runner + materialization golden`

---

### S3 — dispatcher wire-up + end-to-end dispatch test (RED → GREEN)

**Goal:** wire the `SReorganize` arm of
`Amaru.Treasury.Build.runBuildExcept` (drop the
`DiagnosticUnsupportedAction "reorganize"` rejection) and the
`SReorganize` arm of `Amaru.Treasury.IntentJSON.translateIntent`
(drop the `Left "translateIntent: 'reorganize' not yet shipped (#46)"`
stub). Promote the S2 golden to drive through `runFromIntent` so
the end-to-end `intent.json → unsigned CBOR` path is asserted.

**Owned files (S3 only):**

- `lib/Amaru/Treasury/IntentJSON.hs` — implement
  `translateIntent SReorganize` (replace stub at line 1468) and the
  `translateReorganize` helper. The translation is essentially
  identity (`ReorganizeInputs` ≅ `ReorganizeIntent` field set; only
  the `NonEmpty` and `ChainContext`-free invariants need
  enforcing).
- `lib/Amaru/Treasury/Build.hs` — wire the `SReorganize` arm at
  lines 150–155: replace the `DiagnosticUnsupportedAction` rejection
  with the `runReorganizeAction` call wrapped in
  `nestActionBuildError BuildActionReorganize`. Re-export `runReorganizeBuild`
  from the dispatcher module's export list (lines 36–44).
- `test/golden/ReorganizeGoldenSpec.hs` — swap the direct
  `runReorganizeBuild` call for `runFromIntent ctx someIntent`
  (parsed from the `intent.json` fixture). Expected bytes
  unchanged. (This is the slice's RED proof: the dispatcher path
  was previously rejecting; now it returns the same bytes the
  direct-runner path produced in S2.)
- `test/unit/Amaru/Treasury/Build/ReorganizeDispatchSpec.hs` (new)
  — focused unit asserting `runFromIntentEither ctx someReorganizeIntent`
  is `Right _` (no longer `Left … UnsupportedAction "reorganize"`).
  Mirror the shape of `GovernanceWithdrawalInitSpec`.

**RED:** swap the golden's call from `runReorganizeBuild` to
`runFromIntent`; the test fails because the dispatcher arm still
rejects with `UnsupportedAction "reorganize"`. Add the focused
dispatch unit test asserting `Right _`; it also fails.

**GREEN:** wire the two arms; both tests flip green.

**Gate evidence for S3:**

- `nix develop --quiet -c just unit` passes.
- `nix develop --quiet -c just golden` passes.
- `nix develop --quiet -c just ci` passes (final all-up gate).
- `./gate.sh` passes.
- Acceptance scenarios from `spec.md` all hold (see "Acceptance
  scenario coverage" matrix below).

**Commit subject:** `feat(tx): wire SReorganize dispatcher arm`

---

## Acceptance scenario coverage matrix

| Spec scenario | Slice | Test/evidence |
|---|---|---|
| US1 Acc. 1 — `runFromIntent` produces golden CBOR + two-UTxO merge | S2 (direct) → S3 (end-to-end) | `ReorganizeGoldenSpec` |
| US1 Acc. 2 — JSON round-trip | S1 | `IntentJSONSpec` (`intentRoundtrip` property) |
| US1 Acc. 3 — `missingUtxosError` on absent treasury UTxO | S2 | unit case in `ReorganizeGoldenSpec` (or new spec) |
| US1 Acc. 4 — every commit passes `./gate.sh` | S1+S2+S3 | gate run per commit + finalization audit |
| US2 Acc. 1 — dispatcher returns `Right _` | S3 | `ReorganizeDispatchSpec` |
| US2 Acc. 2 — `translateIntent` returns `Right _` | S3 | `ReorganizeDispatchSpec` (or `IntentJSONSpec`) |
| US3 Acc. 1 — `just schema-check` green | S1 | `just schema-check` (in `gate.sh`) |
| US3 Acc. 2 — schema field set matches `ReorganizeInputs` | S1 | `docs/assets/intent-schema.json` diff in PR |
| Edge: empty `treasuryUtxos` rejected at parser | S1 | property in `IntentJSONSpec` |
| Edge: empty `treasuryUtxos` defensively rejected at translate | S3 | unit in `ReorganizeDispatchSpec` |
| Edge: same TxIn twice → degenerate | S1 / S3 | settled in slice (likely `nub` at translate; if not, document) |
| FR-015 ExecUnitsExceeded surface | S2 | unit in `ReorganizeGoldenSpec` with a "too many UTxOs" fixture variant |

## Risks + mitigations

- **R1 — `validateFinalPhase1` short-circuits when the tx has
  withdrawals.** `lib/Amaru/Treasury/Build/Common.hs:120` returns
  `Right ()` unconditionally when `hasWithdrawals tx`. Because A1
  wires permissions withdraw-zero, the existing path will NOT phase-1
  validate the reorganize tx. **Mitigation:** S2 implements a
  separate exec-units check (sum `ccEvaluateTx` results, compare to
  `pparams.maxTxExecutionUnits`) and surfaces
  `DiagnosticExecUnitsExceeded`. See [`research.md`](./research.md) §3.
- **R2 — `tx-build --intent` becomes capable of producing real
  reorganize bytes once S3 lands.** This is a behavior change on
  the shipped CLI (no parser change). It is the intended effect of
  the slice. PR body and PR review must surface this so reviewers
  do not mistake it for an unintended CLI expansion. Captured in
  S3's commit message.
- **R3 — `nestActionBuildError BuildActionReorganize` may not exist
  yet.** The dispatcher's existing arms use
  `nestActionBuildError BuildActionSwap/Disburse/Withdraw`. If
  `BuildActionReorganize` is not a constructor of `BuildAction`,
  S3 also adds it. **Mitigation:** slice executor surveys
  `lib/Amaru/Treasury/Build/Error/Types.hs` first; if missing, adds
  the constructor in S2 (with the diagnostic variant) so S3 stays
  surgical.
- **R4 — fixture forging.** Building a synthetic `ChainContext`
  with valid Conway-era UTxOs, the deployed-script refs, the
  permissions reward account, and pparams is non-trivial. The
  withdraw fixture at `test/fixtures/withdraw/synthetic/` is the
  closest template; we adapt it (different treasury redeemer + N
  inputs instead of one). **Mitigation:** S2 fixture is hand-crafted
  per the withdraw template; provenance recorded in
  `provenance.md` (which envelope each UTxO came from).
- **R5 — non-DevNet networks.** The library core is
  network-agnostic; the wizard #187 enforces DevNet. We must
  NOT add a `requireDevnet` arm for `SReorganize` (other operational
  arms — swap, disburse, withdraw — do NOT have one). **Mitigation:**
  spec is explicit; reviewer checks during S3 review.
- **R6 — multi-scope reorganize.** Spec edge case: a `Reorganize`
  intent whose treasury UTxOs span more than one treasury address
  is structurally invalid. **Mitigation:** S3's `translateReorganize`
  inspects `ccUtxos` projections (resolves each `txin` to its
  output address) and rejects mismatches with a typed error.
  (Alternatively, this lives in the wizard. Slice picks one.)

## Proof strategy summary

Every behavior change has a paired RED/GREEN in **the same commit**:

- **S1 — RED:** intent-JSON round-trip generator references new
  fields → compile or test fails. **GREEN:** real records + JSON
  instances → property passes.
- **S2 — RED:** `expected.cbor` missing → golden fails. **GREEN:**
  runner + program + fixture → byte-stable.
- **S3 — RED:** `runFromIntent` arm rejects → end-to-end test
  fails. **GREEN:** dispatcher + translate wired → bytes match.

The amend-once-on-acceptance rule (mark `tasks.md` checkboxes in
the same slice commit) applies — see the `gate-script` skill's
"Stamping a reviewed slice" section.

## Live-boundary diagnostic

> "What system boundary does this exercise that the unit suite cannot?"

**Answer: none, by design.** This slice is the library core. The
live-system boundary (cardano-node N2C, real chain tip, real
pparams, real exec-units evaluator) is the wizard #187's and the
smoke #87's concern. The library's exec-units check (FR-015) runs
against the *frozen* `ChainContext.ccPParams` and the
`ChainContext.ccEvaluateTx` callback, both of which are mocked at
fixture time — unit-testable, deterministic, no live boundary.

This is explicitly acceptable per the `live-boundary-smoke` skill:
the library has no boundary to smoke. Sibling tickets carry the
live-boundary responsibilities:

- **#187** — DevNet N2C resolver + chain tip + pparams + UTxO query.
- **#87** — live `tx-validate` on Conway, exec-units assertion via
  `assert_execution_units.sh` parity.

No operator follow-up named in this PR — sibling tickets are
already filed and depend on this merging first.

## Deliverables enumeration (peer-surface coverage)

For each deliverable in `spec.md` § Deliverables:

| Deliverable | Peer artifact | Peer surfaces | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Tx/Reorganize.hs` (real) | `lib/Amaru/Treasury/Tx/Withdraw.hs` | `library` stanza only | yes (S1+S2) |
| `lib/Amaru/Treasury/Build/Reorganize.hs` (new) | `lib/Amaru/Treasury/Build/Withdraw.hs` | `library` stanza only | yes (S2) |
| Dispatcher arm | `Build.hs` `SWithdraw` arm | `library` stanza only | yes (S3) |
| `ReorganizeInputs` JSON shape | `WithdrawInputs` JSON shape | `intent-schema.json` published in `docs/assets/` | yes (S1) |
| Intent JSON roundtrip golden | `IntentJSONSpec` `withdraw` entry | `test-suite unit-tests` | yes (S1) |
| Builder materialization golden | `WithdrawGoldenSpec` | `test-suite golden-tests` | yes (S2) |
| Frozen fixture dir | `test/fixtures/withdraw/synthetic/` | (test fixture only) | yes (S2) |

The peer for this slice is `Withdraw` (one wallet input + script
spend + withdraw-zero + one output + signer + validity bound — same
*shape*, different *redeemer* and N-input vs 1-input). Found via
`git grep -l 'Build.Withdraw' .github/ flake.nix nix/ docs/ README.md`:

```
$ git grep -l 'Tx.Withdraw\|Build.Withdraw' amaru-treasury-tx.cabal lib/
amaru-treasury-tx.cabal
lib/Amaru/Treasury/Build.hs
lib/Amaru/Treasury/IntentJSON.hs
lib/Amaru/Treasury/Tx/Withdraw.hs
```

No `.github/workflows/release.yml` / `nix/release.nix` / README /
CHANGELOG mention of `Tx.Withdraw` or `Build.Withdraw` — they are
library-internal modules. **Conclusion: no release / packaging /
docs surfaces are involved in this slice.** The asciinema cast +
README section live with the operator surface in #188.

## Phase-stop assets ready

- [x] `gate.sh` committed (bf348ad3)
- [x] `spec.md` committed + amended (f7267027 + 079e9baa)
- [ ] `plan.md` committed (this commit)
- [ ] `research.md`, `data-model.md`, `contracts/` committed in
      same plan commit
- [ ] Block on `Q-002-plan-ready` for plan-review verdict
- [ ] After verdict: `tasks.md` (`/speckit.tasks`) → analyzer pass
      → S1 dispatch → S2 → S3 → finalization
