# Resume — Epic A (#485): certify operation without Aiken modifications

You own epic #485 in `lambdasistemi/amaru-treasury-tx`, milestone 1. Load `orchestrator-contract`,
`epic-orchestrator`, `resolve-epic`, `context-compiler`, `worker-protocol`, `tmux-orchestrator`,
`invariants`. Read `.milestones/1/{ledger,registry,description,state,session}.md`,
`.milestones/1/session-epic-a.md`, `.milestones/1/resume/eTBD-boundary.md`, and your runtime root
`/tmp/ms-amaru-treasury-1/epic-a/{brief.md,STATUS.md,inbox/}` in full.

## Terminal condition

Operator: *stop when you have certified we can operate without aiken modifications.*

Deliver exactly one verdict, then stop:

- **`CERTIFICATION-PASS`** — mechanically proven that the **deployed** WingRiders V2 scripts support,
  **unchanged**, (a) quote-bound ADA→USDM order creation, (b) settlement into an Amaru treasury
  output that is **subsequently spendable**, and (c) operational reclaim under the existing
  single-pubkey rule; with an explicit statement that no Aiken / validator / fork / redeployment
  change is required.
- **`CERTIFICATION-FAILED`** — the exact boundary requiring an on-chain change, named, with work
  stopped there and no design or implementation of the change.

## The certification spans two validator families

Not only WingRiders. The deployed **Amaru treasury validator** is equally an Aiken artifact holding
real value. If the WingRiders compensation output is unspendable by the unchanged Amaru validator,
the remedy would be an Amaru Aiken change — that is `CERTIFICATION-FAILED` just as much as a
WingRiders change would be. **This seam is the decisive question**, and it is the one no unit test
on either side can see: each validator is internally consistent; only a check that crosses the
boundary can observe the disagreement.

## Certification questions

| ID | Question | Fails certification if |
|---|---|---|
| CQ1 | Are the deployed V2 request validator and ADA/USDM pool identifiable and their parameters observable on mainnet? | the deployed artifacts cannot be reconciled with any published source |
| CQ2 | Can a quote-bound ADA→USDM request be expressed in the deployed request datum with a **script** beneficiary (the Amaru treasury)? | the deployed request/pool validator rejects a script beneficiary or the compensation datum we need |
| CQ3 | Is the resulting compensation output **spendable by the unchanged deployed Amaru treasury validator**? | it is not, and only a validator change would make it so |
| CQ4 | Is reclaim operable under the existing single-pubkey rule with bounds achievable purely **off-chain**? | bounding the exposure provably requires an on-chain change |

CQ4 note: the deployed rule is already known to be one pubkey with unconstrained outputs. That is a
**custody weakness, not necessarily a certification failure** — it fails only if the operational
bound cannot be built off-chain. Do not conflate "worse than Sundae's two-of-four" with "requires an
Aiken change". They are different findings and the report must keep them apart.

## Hard stops

No WingRiders or Amaru contract modification, fork, redeployment, or upstream dependency. No mainnet
submission, signing, cancellation, or treasury-value movement. The eight outputs of
`57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519` remain untouched. Read-only chain
observation through `/code/cardano-mainnet/ipc/node.socket` is not a mutation.

## Evidence standard

Mechanically captured output with real exit codes. A hand-authored transcript is a claim, not
evidence. Every "we observed X" needs a positive control showing the method can find something known
to be there — otherwise a zero result is indistinguishable from a broken query. Every "the validator
rejects Y" needs the rejection actually demonstrated, not cited from an upstream source comment.

## Current stage

Bootstrap complete: runtime root, parent issue #485, ordered children #486–#490 (retained as the
prepared future implementation map, **not dispatched**), worktree, session fragment. Certification
evidence campaign is the remaining work; the milestone desk accepts the verdict independently.

## Closure duties held by the epic owner (rulings A-002, 2026-08-07)

These are **mine at epic close**, not the certification lane's. If this lane dies, its successor
inherits them.

### Verdict rendering

If contract certification passes while agent acceptance is unproven, the operator-facing headline is
verbatim:

```
NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING PILOT
```

A `CERTIFICATION-PASS` certifies deployed-contract compatibility and the absence of a required
Aiken/validator/fork/redeployment change. **Nothing more.** It is not production readiness and not
proof the live WingRiders off-chain agent will batch the order. The residual single-pubkey custody
exposure gets its own top-level section requiring explicit operator acceptance — never a footnote,
because a PASS is not risk mitigation against someone holding that key.

### Registry waivers to write at closure

Record this dated waiver on **every** relevant `NONE` entry in `.milestones/1/registry.md`:

> Research-only stop condition; observation captured but enforcement not commissioned. No operational
> reliance is permitted. Ownership returns to M1 on explicit operator resumption.

The dated certification report is the **observation artifact** — not an enforcing check and not an
owner. Allocation of the two contracts that outlive this epic:

| Contract | Allocated to | Dispatched |
|---|---|---|
| `quote-to-order-binding` | future Epic B | no |
| `wingriders-live-agent-acceptance` | future standalone bounded mainnet pilot, operator acceptance authority | no — uncommissioned and waived for this closure |

### The eight live Sundae orders — explicit custody statement

On-chain custody of the eight `57faba5b…` outputs remains with the `network_compliance` scope's
existing **two-of-four owners**. During the post-closure gap the **operator** retains decision
authority. **This milestone claims no autonomous watcher and no migration authorization.** Any cancel,
rerate, or migration requires a new operator-authorized continuation.

Verified on chain 2026-08-07 (Koios, with a negative control proving the query reports absence):
outputs `#0..#7` all `spent=false`, `n=8`.

### Two ADA totals, both authoritative

| Quantity | Value |
|---|---|
| total swap offer encoded in the eight order datums | `209,424.083770 ADA` |
| total lovelace locked at the eight order outputs | `209,450.323770 ADA` |

Delta `26.240000 ADA` = `8 × 3.28`, being `2 ADA` Sundae min-UTxO deposit + `1.28 ADA` Sundae V3 max
protocol fee. Corroborated at `specs/008-disburse-includes-overhead/spec.md:66` and
`lib/Amaru/Treasury/Constants.hs:85`. **Name which quantity is meant; never replace one with the
other.**

## Escalation

- registry/contract changes, cross-epic ownership → milestone desk `%5803`
- live-host mutation → write `/tmp/machine/owner-opus5-takeover/inbox/NOTE-<lane>-<slug>.md` and send
  **nothing**; `%5234` is reserved for the four incident classes in
  `/tmp/machine/RULE-inbox-not-input-2026-08-07.md`
- reclaim key identity, caps, pilot go, migration go → operator, via the milestone desk. Parked.
