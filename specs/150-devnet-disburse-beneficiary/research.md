# Research: DevNet Disburse Action And Beneficiary Receipt

## Decision: Ship `devnet disburse-submit`

**Decision**: Add a DevNet-only command named `disburse-submit`.

**Rationale**: #150 is a submitted transaction proof, not another
initiator that prepares prerequisites. The verb `submit` makes the user
story concrete and distinguishes it from `disburse-wizard`, which only
resolves an intent.

**Rejected alternatives**:

- Reuse `disburse-wizard`: rejected because the issue requires signing,
  submission, and beneficiary receipt proof.
- Reuse `tx-build`: rejected because #151 requires an operator-facing
  bootstrap command, not a loose smoke script around a generic builder.
- Name it `disburse-init`: rejected because the command submits a
  beneficiary action rather than initializing prerequisite state.

## Decision: Consume #149 `materialized.json`

**Decision**: The command consumes
`governance-withdrawal-init/materialized.json` as the treasury UTxO
source.

**Rationale**: #149 exists to materialize spendable ADA at the treasury
script address for #150. Re-running governance or discovering arbitrary
treasury UTxOs would blur child-ticket boundaries.

## Decision: ADA-only first slice

**Decision**: The first #150 live proof is an ADA disburse.

**Rationale**: The #149 handoff materializes ADA only. USDM disburse is
already covered by structural builder/resolver tests, but a live USDM
proof requires additional token setup not present in the parent ticket.

## Decision: Production module plus CLI runner

**Decision**: Add a production-backed DevNet module analogous to the
previous DevNet initiators, and wire it through `devnet disburse-submit`.

**Rationale**: The command needs DevNet-only submission and verification
logic while still delegating intent/transaction construction to the
existing production disburse and tx-build paths.

## Decision: Thin smoke proof

**Decision**: Add a `disburse-submit` smoke phase that runs
registry-init, stake-reward-init, governance-withdrawal-init, then
calls the #150 production command runner.

**Rationale**: This proves the entire bootstrap chain without moving
the transaction construction back into `SmokeSpec.hs`.
