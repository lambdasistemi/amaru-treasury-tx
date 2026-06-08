# Spec — Operate UI: Contingency Disburse mode (#329)

Parent epic #325. Depends on #327 (the `/v1/build/contingency-disburse`
endpoint). Stacked on `feat/327`. Top of the stack — when this works
end-to-end, the whole #326→#327→#329 stack merges together.

## P1 user story

As a treasury operator, I select "Contingency Disburse" in the Operate
page, add one or more destination-scope + ADA rows, and observe one
unsigned transaction (intent.json + CBOR + report) paying each scope
from the contingency treasury.

## Functional requirements

- FR1 — `OperatePage` gains a 4th transaction mode
  `ModeContingencyDisburse`, surfaced in the mode selector as
  "Contingency Disburse".
- FR2 — The contingency form renders **add/remove destination rows**;
  each row is a scope selector (the four owned scopes — Core Development,
  Ops and Use Cases, Network Compliance, Middleware; **not** Contingency)
  plus an ADA amount input. Plus the shared fields the contingency build
  needs: wallet address, metadata path, validity hours, description,
  justification. No beneficiary-address field, no unit selector (ADA
  fixed).
- FR3 — The mode POSTs to `/v1/build/contingency-disburse` with
  `{ walletAddr, metadataPath, destinations: [{ scope, amountAda }],
  validityHours?, description, justification }` and renders the same
  success surface (intent.json, CBOR hex, envelope, report) and typed
  failure tags as the existing three modes (response is
  `DisburseBuildResponse`-shaped).
- FR4 — The UI rejects an empty destination list (and a Contingency
  destination) before POSTing.

## Success criteria

- The frontend bundle builds (`nix build .#frontend`).
- Browser smoke: select Contingency Disburse, add two destination rows,
  submit against a running API, and see the unsigned-tx result render.

## Exclusions

- No backend/API changes (delivered by #327). No signing/submission.
- The fee-allocation balancer issue (fee skimmed off a beneficiary) is
  tracked as an acceptance check here but its fix lives in the build
  layer; the UI surfaces whatever the endpoint returns.
