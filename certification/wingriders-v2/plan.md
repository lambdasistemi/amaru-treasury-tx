# Certification plan

## Strategy

1. Prove local-node freshness and query reachability with a known-present
   positive control.
2. Use a read-only index only to discover candidate deployment outrefs;
   re-query every certified value through the local mainnet node.
3. Independently pin the two named WingRiders upstream commits and the
   deployed Amaru artifacts already recorded by this repository.
4. Build a throwaway evidence harness under this directory. Exercise the
   deployed scripts offline/read-only with paired red and green cases for
   CQ2 through CQ4. Do not build, sign, stage, or submit a mainnet spend.
5. Hash every raw capture, write a reproducibility manifest, and produce a
   report with one section per CQ and exactly one verdict.
6. Render a PASS as contract compatibility, never production readiness;
   carry the unproven live-agent boundary in the headline and put residual
   single-key custody exposure in its own operator-acceptance section.

## Live boundary

The decisive seam is the WingRiders compensation output consumed by the
unchanged Amaru validator. Unit fixtures or source comments cannot certify
it. The campaign must exercise the deployed bytes with independently
constructed correct and incorrect values.

## Topology

Use `OWNER`: one alternate-provider commit owner owns the complete evidence
bundle and local candidate commit. A fresh Codex auditor independently
checks the exact candidate, raw captures, controls, and gate before the
ticket owner accepts.

## Fence

The only tracked path is `certification/wingriders-v2/**`. No product code,
existing tests, Aiken, package/flake metadata, mainnet mutation, operator
identity, or exposure-cap choice is in scope.

## Ceiling

This plan is limited to 100 lines and 6 KiB.
