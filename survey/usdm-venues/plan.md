# Survey plan

## Strategy

1. Establish node freshness with slot-to-time evidence and a known-present
   UTxO query before trusting the socket.
2. Resolve each named venue from its authoritative validator, factory,
   pool NFT, order book, or quote instrument. Holder ranking is excluded.
3. Re-query discovered on-chain state through the node and freeze one
   coherent quote snapshot with an explicit slot range.
4. Compute fixed-input and realistic-clip executable outputs in integer
   base units, accounting for venue fees and order overhead. Optimise a
   disjoint-pool split and compare router output without adding router
   liquidity to the pool set.
5. Scan the bounded WingRiders V2 history, classify beneficiary
   credentials, link requests to batching transactions, and retain the
   two positive controls required by `INV-BATCHING`.
6. Hash raw captures, run an independently useful verifier with seeded red
   controls, and render the dated recommendation from the evidence.

## Live boundaries

The node is authoritative for current Cardano state. Venue or aggregator
quote APIs are authoritative only for their own executable quote surface;
their underlying on-chain identities are still reconciled through the node.
Historical discovery indexes are accepted only with named coverage limits
and positive controls.

## Topology

Use `OWNER`: one alternate-provider commit owner owns the complete read-only
evidence bundle and local candidate commit. A fresh Codex auditor checks the
exact candidate, quote provenance, controls, arithmetic, route disjointness,
history counts, and safety fence before ticket-owner acceptance.

## Slice

One slice, `S492-SURVEY`, owns the correlated market snapshot, history scan,
verifier, and report. Splitting it would permit quote times, routing inputs,
and verdict arithmetic to drift independently.

## Fence

The only tracked path is `survey/usdm-venues/**`. The accepted #491 branch is
read-only corroboration. No product path, existing test, package metadata,
transaction artifact, signing material, credential, or mainnet state is in
scope.

## Refresh boundary

Current quotes and pool states are `refresh-before-acceptance`. Venue
protocol identities and historical rows are frozen to their cited sources;
any changed current outref or reserve requires a new capture and recomputed
route result, not silent reconciliation.

## Ceiling

This plan is limited to 90 lines and 6 KiB.
