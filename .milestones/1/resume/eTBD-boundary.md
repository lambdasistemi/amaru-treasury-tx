# Bootstrap ask — Epic A: WingRiders deployed-boundary and custody proof

# Objective

Create and own one parent epic whose runnable artifact proves the exact deployed WingRiders V2 ADA/USDM boundary needed by `amaru-treasury-tx`, including settlement into an Amaru treasury and the unavoidable single-pubkey reclaim model.

# Current state

- Home repo: `lambdasistemi/amaru-treasury-tx`; milestone 1.
- Sundae batch `57faba5b…` has eight live unspent orders totaling 209,424.083770 ADA for at least 40,000.000002 USDM.
- Live liquidity observed 2026-08-07: Sundae about 71,526 ADA / 14,453 USDM; WingRiders about 1,782,840 ADA / 360,832 USDM.
- Upstream source: `WingRiders/dex-v2-contracts@280a9e895077ab746c2713880efba79038fea50f` and `WingRiders/dex-serializer@acc572a40acc498a8843db79e2d3afa409f509b1`; both must be reconciled with the deployed scripts rather than trusted by age/name.
- `DEX.Request.pvalidateReclaim` extracts a pubkey credential from `owner` and checks that signature; comments state owner must be a pubkey and may route reclaimed assets arbitrarily.
- `DEX.Pool.pparseRequest` allows a script beneficiary and enforces the requested compensation datum.

# Constraints

- No WingRiders smart-contract modification, fork, redeployment, or upstream dependency. If required, stop that design path.
- No mainnet submission, no cancellation of existing orders, and no movement of treasury value.
- Produce a runnable `wingriders-boundary-probe` artifact, not research prose alone.
- Every reconciliation check needs a negative control proving it can fail.
- Treat all live constants as refresh-before-acceptance.
- You are not alone in the codebase; do not revert edits made by others.

# Task

Bootstrap the epic through `epic-orchestrator` + `resolve-epic`: file the parent and ordered child tickets, add them to the planner, create the epic artifact/release fence, and own execution. Required children must cover: deployed script/pool reconciliation; datum encoder/decoder golden; treasury compensation datum offline replay with a wrong-datum control; reclaim threat model and enforceable operational gates; live-boundary dry run that spends no treasury funds.

# Output contract

Return the epic issue URL, child map/dependencies, artifact/release name, runtime root/window fragment, contract-registry deltas, and the exact evidence for deployed hashes/addresses/fees, compensation compatibility, and reclaim constraints. Escalate any need for contract modification immediately as forbidden scope.
