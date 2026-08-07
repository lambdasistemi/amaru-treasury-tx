# Resume milestone 1 — WingRiders USDM treasury execution

You own milestone 1 in `lambdasistemi/amaru-treasury-tx`. Load `orchestrator-contract`, `milestone-orchestrator`, `context-compiler`, `worker-protocol`, `tmux-orchestrator`, and `invariants`. Read `.milestones/1/{ledger,registry,description,state,session}.md` in full, then verify the current on-chain pending-order count before any state claim.

Current stage: **PARKED under machine-wide OMNIA PAUSA since 2026-08-07T15:28Z. Release belongs to
the machine owner; silence is not permission.** Epic A (#485) is accepted with `CERTIFICATION-PASS`. Exact headline:
`NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING PILOT`. Its drafted implementation children
#486–#490 were not dispatched. Operator ruling “Do it we need the full picture” reopened only
read-only ticket #492 for cross-venue executable quotes and the unbatched-script-beneficiary
investigation. No treasury transaction was mutated.

Load-bearing finding: deployed WingRiders V2 reclaim requires one pubkey owner and allows that signer to redirect reclaimed value. Script/native multisig ownership is not supported. Upstream smart-contract modification is permanently forbidden scope. The milestone therefore uses a visible, bounded operational exception and may not claim equivalence to Amaru's two-of-four Sundae cancellation policy.

Verdict semantics: `CERTIFICATION-PASS` certifies deployed-contract compatibility and no required Aiken/validator/fork/redeployment change; it does not certify discretionary acceptance by the live WingRiders off-chain agent or production readiness. That open contract belongs to the future standalone bounded pilot and requires explicit operator authorization.

Accepted evidence: remote branch
`491-wingriders-certification@4a01c34349d00cb2eaf99717f69e5a46f0a6162b`; report SHA-256
`8d8e083e4416d23e0cb1fa22a8585900de2be86fd8ad64e13d756e8a34477112`; snapshot manifest
`f41fb591…`; evidence manifest `30d00b0b…`. The branch is intentionally CI-red only at format-check
because four Haskell harness files are immutable evidence. Never reformat them; the branch cannot be
merged or PR'd as-is.

Ticket #492 is parked mid-audit at signed local candidate `e3104a42`; 23 observations and successful
full audit CI are banked, but there is no audit verdict or acceptance. Preliminary evidence says no
single venue clears 40,000 USDM and Minswap V2 is deeper than WingRiders; fee-correct totals conflict,
and the only reported material headroom uses an unproven USDCx bridge.

Next action after machine-owner release: resume the existing auditor at its post-CI boundary, obtain
the hash-bound submission-1 verdict, reconcile the fee discrepancy, and explicitly schedule Minswap
V2 cancel/reclaim analysis as a follow-on if still warranted. Do not implement, pilot, cancel, rerate,
migrate, sign a transaction, submit, or move value by inference from the PASS or research.

Human decisions still required before a mainnet pilot: reclaim-key identity, pilot cap, and explicit submit authorization. The eight outputs of `57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519` remain live and must not be cancelled without a separate explicit go.

Order accounting: the eight outputs lock `209,450.323770 ADA` total. Their encoded swap offer is `209,424.083770 ADA`; the exact `26.240000 ADA` delta is `8 × 3.28 ADA` configured overhead (`2 ADA` min-UTxO deposit plus `1.28 ADA` maximum Sundae V3 protocol fee). Custody remains with the `network_compliance` two-of-four owners; during the desk stop, the operator retains decision authority and no autonomous watcher is claimed.
