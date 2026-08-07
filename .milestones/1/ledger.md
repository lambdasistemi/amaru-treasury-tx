# Milestone 1 ledger

## Outcome test

From a clean machine, install the published `v0.3.0-ms1.*` artifact and use it to quote, build, inspect, validate, reclaim, and settle a bounded WingRiders V2 ADA→USDM treasury order. The quote must be bound to the observed pool/deployment; the settlement must land at the `network_compliance` treasury and remain spendable; the reclaim must preserve the complete value; unsafe owner identity, stale quote, wrong deployment, expired deadline, excess exposure, and premature migration must fail closed. A mainnet pilot requires an explicit operator go and is archived through the normal transaction record.

## Artifact

- Milestone line: `amaru-treasury-tx v0.3.0-ms1.*` pre-release.
- Epic artifacts merge into this line; it graduates into the normal release line at milestone close.
- Publication is in scope. Production rollout beyond the authorized pilot is not implied.

## Unit map

| Unit | GitHub | State | Artifact | Dependency |
|---|---|---|---|---|
| Epic A — WingRiders deployed-boundary and custody proof | not filed | 🟡 next | `wingriders-boundary-probe` executable/report | none |
| Epic B — venue abstraction and WingRiders V2 adapter | not filed | ⏳ queued | milestone `amaru-treasury-tx` pre-release | Epic A freezes boundary contracts; internal abstraction may proceed in parallel |
| Standalone — bounded mainnet pilot and archive | not filed | ⏳ queued | archived pilot tx + settlement/reclaim evidence | Epics A+B, operator cap/key decision, explicit submit go |
| Standalone — cancel/migrate eight `57faba5b…` orders | not filed | ⛔ blocked | archived cancels + staged replacements | accepted pilot and separate explicit migration go |

No child lane is dispatched yet. Issue filing and lane bootstrap belong to the future epic/ticket owners, not this desk.

## Priority and rationale

1. Boundary proof first because the upstream published contracts are older than the live pool and the reclaim authority changes the custody model.
2. Adapter design second, with Sundae regression parity as a permanent invariant.
3. Pilot before migration because unit/golden tests cannot prove the live WingRiders agent accepts our datum and the Amaru treasury can later spend the compensation output.
4. Migration last because cancelling the existing orders is destructive and cannot be undone without another signing round.

## Decisions

- WingRiders smart-contract modification is forbidden scope; any requirement for it terminates that design path.
- Use deployed WingRiders V2 only.
- The V2 reclaim owner is necessarily a pubkey. This is not represented as equivalent to Amaru's on-chain two-of-four policy.
- The operational exception must be visible in every inspect/pre-submit brief and mechanically bounded by identity, deadline, per-order cap, and aggregate outstanding cap.
- The eight pending Sundae outputs remain untouched until pilot acceptance and a separate explicit operator authorization.

## Parked decisions

| Decision | Authority | Recommendation | Unblocks |
|---|---|---|---|
| Dedicated reclaim pubkey identity and vault custody | operator | dedicated, non-scope-owner key; no ambient export; exact key hash pinned | WingRiders build/reclaim acceptance |
| Pilot cap | operator | start at 1,000 ADA or less | mainnet pilot |
| Production per-order and aggregate outstanding caps | operator | derive after pilot timing/failure evidence; never default to the full 209k ADA | migration plan |
| Migration go/no-go | operator | decide only from fresh cross-venue executable quotes after pilot | cancellation of `57faba5b…` |

## Immediate next ask

Bootstrap Epic A from the compiled research contract in `resume/eTBD-boundary.md`; it must file its own parent/child issues, establish the executable boundary probe, and return the exact deployed script hashes, request address, pool identity, fees, settlement datum proof, and reclaim-key threat model.
