# Milestone 1 ledger

## Outcome test

From a clean machine, install the published `v0.3.0-ms1.*` artifact and use it to quote, build, inspect, validate, reclaim, and settle a bounded WingRiders V2 ADA→USDM treasury order. The quote must be bound to the observed pool/deployment; the settlement must land at the `network_compliance` treasury and remain spendable; the reclaim must preserve the complete value; unsafe owner identity, stale quote, wrong deployment, expired deadline, excess exposure, and premature migration must fail closed. A mainnet pilot requires an explicit operator go and is archived through the normal transaction record.

## Artifact

- Milestone line: `amaru-treasury-tx v0.3.0-ms1.*` pre-release.
- Epic artifacts merge into this line; it graduates into the normal release line at milestone close.
- Publication is in scope. Production rollout beyond the authorized pilot is not implied.
- Accepted Epic A evidence is preserved, signed, on remote branch
  `491-wingriders-certification@4a01c34349d00cb2eaf99717f69e5a46f0a6162b`.
  It is an immutable evidence branch, not a release artifact and not mergeable as-is: repository
  format-check rejects four manifest-bound harness files whose reformatting would invalidate the
  accepted snapshot hash `f41fb591…`.

## Unit map

| Unit | GitHub | State | Artifact | Dependency |
|---|---|---|---|---|
| Epic A — deployed-boundary and market/custody proof | #485 | ⛔ parked under OMNIA PAUSA; #492 mid-audit | accepted certification `4a01c343`; local survey candidate `e3104a42`, no audit verdict | machine-owner RELEASE, then finish existing audit |
| Epic B — venue abstraction and WingRiders V2 adapter | not filed | ⏳ queued | milestone `amaru-treasury-tx` pre-release | Epic A freezes boundary contracts; internal abstraction may proceed in parallel |
| Standalone — bounded mainnet pilot and archive | not filed | ⏳ queued | archived pilot tx + settlement/reclaim evidence | Epics A+B, operator cap/key decision, explicit submit go |
| Standalone — cancel/migrate eight `57faba5b…` orders | not filed | ⛔ blocked | archived cancels + staged replacements | accepted pilot and separate explicit migration go |

Epic A certified that the deployed WingRiders V2 and Amaru treasury validators support the treasury
path unchanged. Its exact headline remains `NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING
PILOT`. The operator subsequently reopened Epic A for one read-only research ticket, #492. That run
is now parked under the 2026-08-07T15:28Z machine-wide pause with signed local candidate `e3104a42`,
23 manifest-bound observations, full audit CI exit 0, and **no audit verdict or acceptance**. Drafted
implementation children #486–#490 remain undispatched. No implementation, pilot, transaction
signing, submission, cancellation, or value movement is authorized.

All four Epic A panes are alive but idle. Its ticket owner, commit owner, and auditor each recorded
parked state. No owned signed-commit test suite or unattended command remains active. Release belongs
to the machine owner; silence is not permission.

## Priority and rationale

1. Boundary proof first because the upstream published contracts are older than the live pool and the reclaim authority changes the custody model.
2. Finish and accept or reject #492's already-started audit after release. Preliminary instruments
   agree no single venue clears 40,000 USDM and that Minswap V2 is deeper than WingRiders, but their
   fee-correct totals differ; no quote claim is accepted yet.
3. Establish Minswap V2 cancel/reclaim authority and the USDCx bridge's atomicity/recovery semantics
   before selecting a venue or adapter. The single-pubkey risk may be WingRiders-specific.
4. Pilot before migration because unit/golden tests cannot prove the live WingRiders agent accepts our datum.
5. Migration last because cancelling the existing orders is destructive and cannot be undone without another signing round.

## Decisions

- WingRiders smart-contract modification is forbidden scope; any requirement for it terminates that design path.
- Use deployed WingRiders V2 only.
- The V2 reclaim owner is necessarily a pubkey. This is not represented as equivalent to Amaru's on-chain two-of-four policy.
- The operational exception must be visible in every inspect/pre-submit brief and mechanically bounded by identity, deadline, per-order cap, and aggregate outstanding cap.
- The eight pending Sundae outputs remain untouched until pilot acceptance and a separate explicit operator authorization.
- `CERTIFICATION-PASS` means deployed-contract compatibility and no required Aiken/validator/fork/redeployment change. It does not prove live WingRiders agent acceptance or production readiness; those remain owned by the future standalone bounded pilot.
- Epic A's accepted report is SHA-256 `8d8e083e4416d23e0cb1fa22a8585900de2be86fd8ad64e13d756e8a34477112`;
  the evidence manifest is `30d00b0b…` and the ticket snapshot manifest is `f41fb591…`. The pushed
  blobs pass 53/53 snapshot entries and 35/35 evidence entries.
- The preservation branch is deliberately CI-red only at format-check. Never reformat the immutable
  harness to make it green. If this evidence is ever proposed for `main`, decide a formatter
  exclusion for `certification/**` explicitly and create a separate integration path.
- The existing orders contain `209,424.083770 ADA` of swap offer and `209,450.323770 ADA` total locked value. The `26.240000 ADA` difference is eight times the configured `3.28 ADA` overhead (`2 ADA` min-UTxO deposit plus `1.28 ADA` maximum Sundae V3 protocol fee).

## Parked decisions

| Decision | Authority | Recommendation | Unblocks |
|---|---|---|---|
| Dedicated reclaim pubkey identity and vault custody | operator | dedicated, non-scope-owner key; no ambient export; exact key hash pinned | WingRiders build/reclaim acceptance |
| Pilot cap | operator | start at 1,000 ADA or less | mainnet pilot |
| Production per-order and aggregate outstanding caps | operator | derive after pilot timing/failure evidence; never default to the full 209k ADA | migration plan |
| Migration go/no-go | operator | decide only from fresh cross-venue executable quotes after pilot | cancellation of `57faba5b…` |
| Resume #492 | machine owner | release only after the host-wide pause ends; resume the existing auditor before opening new research | survey acceptance |
| Venue choice | milestone/operator | do not assume WingRiders; require accepted fee-correct quotes and deployed cancel/reclaim evidence | any adapter or pilot |

Custody of the eight live orders remains with the `network_compliance` scope's existing two-of-four owners. During this desk's post-certification stop, the operator retains decision authority; no autonomous watcher or migration authorization is claimed.

## Immediate next ask

Wait for machine-owner RELEASE. Then finish the existing submission-1 audit of ticket #492, reconcile
venue-correct fees and conflicting totals, and decide explicitly whether the Minswap V2 reclaim study
is a follow-on slice rather than silently changing the frozen audit snapshot. Only after accepted
evidence should the milestone decide whether any adapter or pilot remains justified. Do not infer
authority to implement, pilot, cancel, rerate, migrate, sign, submit, or move value.
