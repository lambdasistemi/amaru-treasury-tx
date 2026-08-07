# COMPLETE RUNTIME-VERDICT HANDOFF — issue #491

Worker `ticket-491/commit-owner-1`, pane `%5822`, `claude` /
`claude-opus-5`. Base `a730adb9b3d1130b896fddf17d1b7ab363921c0c`.
Gate `662068b03dc1c30acd897341e887994fe58474f0329becf0438982b2142fabfc`
(re-verified by hash at drafting time).

Compiled 2026-08-07 UTC. This is the terminal runtime handoff requested by
NOTE-005. Everything below lives under `commit-owner-1/` only.

---

## 1. Verdict

**`CERTIFICATION-PASS`**

**NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING PILOT**

No Aiken change, no validator change, no fork and no redeployment is
required on either side. All four certification questions are evidenced
against **deployed bytes**, each with a green and at least one paired red
demonstrated in the same instrument.

The verdict is drafted, not published: it lives in `draft/report.md` and
has not been written to the issue worktree.

## 2. Containment — every hold observed

| Hold | State |
|---|---|
| issue worktree | untouched, `HEAD=a730adb9`, `git status` empty |
| stage / commit / sign / push | none; signing remains suspended |
| mainnet write, signing, submission, cancellation, value movement | none |
| old-pin haskell.nix/IFD source build | never started; declined per NOTE-002 |
| eight outputs of `57faba5b…` | read as a positive control, untouched |
| discovery credential | confined to `scratch/.bf-token` (0600); absent from the worktree, from `evidence/`, and from every recorded command |

No `RED-COMMIT`, `GREEN-COMMIT` or `PROOF-COMPLETE` is claimed — all three
require repository writes that remain forbidden.

## 3. Artifacts

Ready to materialize under `certification/wingriders-v2/**` on branch
`491-wingriders-certification` once signing is restored:

| Draft | Becomes |
|---|---|
| `draft/report.md` | `report.md` |
| `draft/verify-evidence.sh` | `verify-evidence.sh` (executable) |
| `draft/README.md` | `README.md` |
| `evidence/` (35-entry `SHA256SUMS`, 3.3 MiB) | `evidence/` |

Harness sources under `scratch/` (`PoolReplay.hs`, `Cq4Reclaim.hs`,
`Cq3Treasury.hs`, `EvalProbe.hs`, `observe`, `bf`, `replay-tx`,
`gen-context.jq`, the panels) are the throwaway `MOD-HARNESS` tooling and
should be materialized with them.

**Do not materialize `scratch/.bf-token`.**

Budget: 3.3 MiB against the 30 MiB tracked ceiling.

## 4. Gate readiness — dry-run result

Against the hash-verified immutable gate: **all 22 report checks pass**,
the write-capable-command scan over the harness finds nothing, and all
four required verifier markers are present. The gate's remaining checks
(base commit, path fence, `git diff --check`, `SHA256SUMS` check) can only
run after materialization.

## 5. Evidence index

| Claim | Evidence | SHA-256 |
|---|---|---|
| node freshness t0/t1 | `raw/tip-freshness-t{0,1}.log` | `f165f92b…` / `be60b4eb…` |
| presence control | `raw/positive-control-known-present.log` | `2ddf8a16…` |
| absence control | `raw/absence-control-known-absent.log` | `44136fa3…` |
| evaluator trap + corrected control | `raw/evaluator-instrument-request{,-v2}.log` | `d89a7378…` / `c9554cdb…` |
| CQ1 pool state | `raw/cq1-pool-address-utxos-node.log` | `058d7c7c…` |
| CQ1 deployed scripts | `raw/cq1-reference-scripts-node.log` | `7af73045…` |
| replay fidelity panel (11 batches) | `raw/cq2-replay-fidelity-panel.log` | `81007248…` |
| **CQ2 controls** | `raw/cq2-script-beneficiary-controls.log` | `50d94924…` |
| **CQ3 controls** | `raw/cq3-treasury-spend-controls.log` | `989dff2e…` |
| **CQ4 controls** | `raw/cq4-reclaim-controls-v2.log` | `626c73c8…` |
| CMD-VERIFY clean run | `receipts/cmd-verify-clean.log` | `316c6b52…` |

Every row in `evidence/observations.jsonl` carries CQ ID, UTC, observed
slot, source kind, pin/outref, command, **real** exit code, raw-log path
and SHA-256.

## 6. Invariant → evidence map

| Invariant | Green | Red / control | Result |
|---|---|---|---|
| `INV-CQ1-IDENTITY` | request + pool identified from node at slots 194528829–194529023; address↔datum and address↔refscript bindings with non-shared sides | discovery outref returned `{}` at the node; presence/absence controls | satisfied |
| `INV-CQ2-BENEFICIARY` | script beneficiary + requested inline datum accepted | wrong beneficiary / wrong datum / no datum all rejected; unmutated control green | satisfied |
| `INV-CQ3-SPEND` | datum-carrying treasury input spendable by unchanged deployed V3 validator | diverted treasury change rejected; base real spend green | satisfied |
| `INV-CQ4-RECLAIM` | pubkey owner signed accepted | no signature / wrong signatory / **script owner** rejected; under-application trap retained | satisfied |
| `INV-EVIDENCE` | 35-entry manifest, real exit codes, per-CQ paired reds | `CMD-VERIFY` rejects tampered, missing and vacuous evidence | satisfied |
| `INV-SAFETY` | read-only throughout | credential and worktree containment proven | satisfied |
| `INV-REGISTRY` | dated report, slots/pins/outrefs per CQ, `Registry enforcement: NONE`, deltas, one verdict | gate dry-run | satisfied |

## 7. What a PASS does **not** mean

- **No byte-level source equality.** It was not established and is not
  relied upon. Every upstream citation is labelled *not verified against
  the deployment*. Per NOTE-002 no certification claim rests on source.
- **No live-operability claim.** `wingriders-live-agent-acceptance`
  remains uncommissioned and waived for this research-only closure.
  Empirically, all three script-beneficiary requests on mainnet expired
  unbatched; one was satisfiable with a 12.89 % surplus at the reserves
  observed on 2026-08-07, but that uses today's reserves rather than
  those before its deadline, so **the cause of non-batching is not
  established and is not asserted**.
- **No custody acceptance.** Residual single-key custody exposure has its
  own top-level section and requires explicit operator acceptance before
  any pilot. Issuing this report does not grant it.

## 8. Known limitations, stated not buried

1. **V3 replay fidelity.** The CQ3 base replay consumes ~1.9 % *more*
   than the on-chain declared budget, so that context is not proven
   byte-faithful — unlike the V2 pool context, whose deficit was a
   workload-invariant constant across 11 batches. CQ3 still stands
   because the base validates, the invalid control rejects, and the datum
   axis moves the budget by **exactly zero**. A byte-faithful V3 replay
   would be a genuine improvement.
2. **CQ4 custody is a bounded result.** "No output constraint was
   observed across 8 evaluated cases" — evaluation cannot prove the
   universal negative.
3. **Swap-offer total not re-derived.** Only the locked-output total was
   independently re-derived (`209450323770` lovelace, exact). Both are
   labelled in the report and the distinction is disclosed.
4. **Single mutated batch for CQ2.** The CQ2 mutation set runs on one
   validated context; the 11-batch panel establishes context fidelity, not
   CQ2 coverage across batch shapes.

## 9. Registry deltas for the milestone owner

- Deployed Amaru treasury is **PlutusV3** `32201dc1…`; the vendored
  blueprint records the unparameterised `3c6cf297…`. Consumers must not
  treat the blueprint hash as the deployed hash.
- The two pinned WingRiders commits are not contemporaneous with each
  other or with the deployed pool datum (16 modelled fields vs 21).
- Deployed pool `swapFeeInBasis` is 20; upstream default is 30.
- Issue #491's deliverable text names branch `e485-certification` and
  `.milestones/1/`; the frozen plan and immutable gate name
  `491-wingriders-certification` and `certification/wingriders-v2/**`.
  This lane followed the gate. The `.milestones/1/` integration record is
  a later epic-level responsibility and was **not** written here.
- `wingriders-live-agent-acceptance` remains open with no enforcing check.

## 10. Next actions — ticket owner

1. Re-sign planning, re-version base/gate/packet, deliver a durable
   correction restoring signing, and require `RESUMED`.
2. On resumption I materialize the four drafts plus the harness into
   `certification/wingriders-v2/**`, run `./gate.sh` and
   `nix develop --quiet -c just ci`, and produce the RED/GREEN commits and
   `PROOF-COMPLETE`.
3. Dispatch a fresh `codex-raw` auditor against the exact candidate.

**Parked write-idle.** No further runtime work is pending; I stop here per
NOTE-005 unless a new question, correction, or the signing restoration
arrives.
