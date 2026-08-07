Outcome: a released `amaru-treasury-tx` can safely quote, build, inspect, reclaim, and settle bounded ADA→USDM swaps through the deployed WingRiders V2 pool into an Amaru treasury, then migrate the pending network-compliance batch only after an operator-authorized pilot.

Observable test: install the milestone pre-release on a clean host; bind a quote to the observed mainnet WingRiders pool and deployed scripts; build and validate an order whose USDM settlement returns to the network-compliance treasury; prove the reclaim path returns the complete order value; execute and archive an explicitly authorized bounded mainnet pilot; reject stale quotes, wrong deployments, unsafe owner identities, excess exposure, and any attempt to migrate the eight pending Sundae orders before pilot acceptance.

Artifact: `amaru-treasury-tx` `v0.3.0-ms1.*` pre-releases, graduating into the normal release line only after the outcome audit.

Scope boundaries: use the already-deployed WingRiders V2 contracts; no WingRiders smart-contract modification or upstream protocol dependency; no cancellation of transaction `57faba5b…`, no mainnet WingRiders submission, and no full-value migration without separate explicit operator approval. The deployed V2 single-pubkey reclaim authority is treated as a disclosed operational risk with a fail-closed exposure cap, short deadline, and named vault identity.

Live state: https://github.com/lambdasistemi/amaru-treasury-tx/wiki/M1-State
