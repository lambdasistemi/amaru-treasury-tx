# Plan Review: Local Devnet Smoke

## Verdict

Approved for implementation in solo PR mode.

## Evidence

- The plan connects directly to the accepted Spec Kit requirement:
  local live verification using the pinned `cardano-node-clients`
  devnet with a short epoch.
- It preserves the constitutional boundary that release-facing Amaru
  commands build unsigned transactions only.
- It names the main design choices: reuse
  `cardano-node-clients:devnet`, add a local-only `devnet` network
  alias, keep the smoke opt-in, and split node/withdraw/disburse
  phases.
- It identifies the risky boundary: any chain seeding must remain
  smoke harness setup, not CLI behavior.
- It now defines review slices so behavior changes can be committed
  with their RED/regression proof and GREEN implementation together.

## Conditions

- The first implementation slice should be the `devnet` network
  identity slice or the node smoke slice; do not start withdrawal or
  disburse/build until the node boundary is proven.
- Live smoke commands are manual evidence and must not be added to
  default `just ci`.
