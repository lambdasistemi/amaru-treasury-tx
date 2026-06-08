# Spec — /v1/build/contingency-disburse (API) (#327)

Parent epic: #325. Depends on #326 (build path). Stacked on `feat/326`.
The UI (#329) stacks on this; the whole stack merges together once the
UI works.

## P1 user story

As a treasury operator (or the Operate UI), I POST a wallet address,
metadata path, and a non-empty list of `(destination scope, ADA)` to
`/v1/build/contingency-disburse` and receive an unsigned transaction
(intent.json + CBOR + report) paying each scope from the contingency
treasury.

## Functional requirements

- FR1 — A pure builder `buildContingencyDisburseIntent` (sibling of
  `Wizard.Disburse.buildDisburseIntent`) verifies the registry for
  `Contingency ∪ {destinations}`, resolves each destination scope's
  treasury address from verified metadata, builds the contingency
  `DisburseAnswers` (scope = Contingency, ADA, the destination list with
  fixed rationale), and returns a typed intent. Reuses `buildDisburseTx`.
- FR2 — `Amaru.Treasury.Api.BuildContingencyDisburse` exposes a wire
  request `{ walletAddr, metadataPath, destinations: [{scope, amountAda}],
  validityHours?, description, justification }`, a mapper to the
  contingency opts, and a runner; reuses `DisburseBuildResponse`.
- FR3 — `/v1/build/contingency-disburse` is wired into `JsonAPI`, the
  `Handlers`/`BuildHandlers` records, `mkBuildHandlers`, and the api
  binary (`app/amaru-treasury-tx-api/Main.hs`).
- FR4 — The mapper/builder rejects `Contingency` as a destination and an
  empty destination list (typed failure).
- FR5 — Each destination is funded with the exact authored ADA; the tx
  fee comes from wallet fuel/change, not skimmed off a scope output
  (verify against the #326 slice-C finding).

## Success criteria

- `just ci` green; handler/mapper unit tests in `ServerSpec`.
- A live API smoke builds a 2-destination contingency disburse and
  returns intent.json + CBOR + report (no signing).

## Exclusions

- No UI (#329). No signing/submission. No changes to the swap / disburse
  / reorganize endpoints. ADA only.
