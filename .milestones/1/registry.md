# Contract registry

## wingriders-v2-deployment

contract: published WingRiders V2 source and datum schema correspond exactly to the deployed ADA/USDM constant-product pool and request validator.

parties: WingRiders upstream contracts; `amaru-treasury-tx` constants and encoder.

invariant: pool identity, pool type, request validator hash/address, assets, scales, request oil, agent fee, swap fee, protocol fee, and script language/version are derived from or reconciled with current on-chain state; a wrong or stale deployment is rejected.

enforced: NONE — Epic A must add a declared-vs-observed reconciliation with a deliberately wrong-hash negative control.

## wingriders-request-datum

contract: `amaru-treasury-tx` emits the deployed V2 `RequestDatum` and `Swap` action wire format.

parties: WingRiders V2 request/pool validators; Amaru Haskell encoder, intent schema, inspector.

invariant: every field and constructor matches a real mainnet request fixture and the pinned upstream CDDL/source; malformed direction, asset, deadline, datum mode, scale, oil, or minimum output is rejected.

enforced: NONE — requires golden round-trip plus one-field mutation negative controls.

## treasury-compensation-output

contract: WingRiders settlement pays USDM and residual ADA to the exact Amaru scope treasury in a datum form that the treasury validator can subsequently spend and the inspector attributes correctly.

parties: WingRiders pool validator; Amaru treasury validator, inspector, and history/archive.

invariant: beneficiary is the `network_compliance` treasury script; the compensation datum is validator-compatible; no value is diverted; a subsequent treasury transaction spends the output.

enforced: NONE — requires offline replay against the real validators, wrong-datum negative control, and bounded live pilot.

## reclaim-authority

contract: WingRiders V2 `Reclaim` requires the datum's owner pubkey signature and otherwise leaves outputs unconstrained.

parties: deployed WingRiders request validator; operator vault/key custody; Amaru reclaim builder and pre-submit review.

invariant: owner is a named dedicated pubkey hash; no claim of on-chain two-of-four protection is made; build refuses unknown identity, excess per-order/aggregate exposure, or missing/expired policy inputs; reclaim report proves complete return to the treasury.

enforced: NONE — deployed contract enforces only one pubkey. Milestone must commission operational gates and negative controls; full-value use needs explicit operator acceptance of the residual trust.

## quote-to-order-binding

contract: a live executable quote becomes the minimum output, chunking, deadline, and exact observed pool state used by the built order.

parties: quote source/pool observer; WingRiders intent and build pipeline.

invariant: spot price alone is never accepted; quote age and pool outref/hash are reported; stale or changed state fails/requotes; total worst-case output and all fees are visible.

enforced: NONE — existing Sundae quote derivation does not cover WingRiders or bind the deployment.

## venue-tagged-intent

contract: Sundae and WingRiders orders share treasury funding/governance logic without interpreting one venue's fields as the other's.

parties: intent JSON/schema, wizard, builder, inspect/report/history, HTTP/frontend surfaces.

invariant: the venue is explicit and exhaustive; old Sundae intents retain byte/behavior parity; unknown/mixed fields fail; reports name the venue and venue-specific risk.

enforced: NONE — current schema and 98 source/test/doc files are Sundae-specific.

## migration-sequencing

contract: the eight live Sundae orders are cancelled only after WingRiders pilot acceptance and explicit operator authorization, and every destructive transition is archived.

parties: `swap-cancel`, WingRiders replacement flow, transaction archive, human approval.

invariant: no cancellation is built or submitted from milestone preparation; cancellation and replacement txids are cross-linked; fresh quotes precede each staged replacement; outstanding exposure never exceeds the approved cap.

enforced: existing submit approval and archive checks cover individual transactions; the cross-venue sequencing gate is NONE.
