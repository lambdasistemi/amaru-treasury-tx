# Plan — Operate UI: Contingency Disburse mode (#329)

Stacked on `feat/327` (HEAD c7c68a1f — the endpoint). Frontend is
PureScript/Halogen in `frontend/src/OperatePage.purs` (unchanged by
#326/#327, which were backend-only). No frontend unit-test harness →
proof is `nix build .#frontend` + a browser smoke.

## Endpoint contract (frozen by #327)

`POST /v1/build/contingency-disburse`
request `{ walletAddr, metadataPath, destinations: [{ scope, amountAda }],
validityHours?, description, justification }`
response: `DisburseBuildResponse` shape (intentJson, cli, cborHex,
cborEnvelope, report, failureTag, failureField, failureReason,
buildFailureTag) — render identically to the disburse mode.

## Single slice — Contingency Disburse mode end-to-end

Mirror the existing `ModeDisburse` wiring; the deltas vs disburse are:
destination **rows** (scope+ADA) instead of one beneficiary address, and
no unit selector (ADA fixed).

Touch points in `OperatePage.purs`:
- `data TxMode` → add `ModeContingencyDisburse`.
- `modeSelector` → 4th button "Contingency Disburse".
- mode title/label case.
- `State` → a `contingencyDestinations :: Array { scope :: String, ada :: String }`
  field (or similar) + add/remove handlers (`Action` constructors).
- the form render `case st.mode of … ModeContingencyDisburse -> …` —
  destination rows (scope `<select>` over the four owned scopes + ADA
  input, add/remove buttons) + the shared wallet/metadata/validity/
  description/justification fields.
- request JSON builder `contingencyDisburseRequestJson st` →
  `{ walletAddr, metadataPath, destinations: [...], validityHours?,
  description, justification }`.
- `postBuild "/v1/build/contingency-disburse" st` in the build dispatch.
- `modeToString` / `stringToMode` → `"contingency-disburse"`.
- every exhaustive `case … of` over `TxMode` (PureScript will flag each
  with `-Wincomplete-patterns`/build error — handle them all).
- client-side guard: empty destinations / Contingency scope rejected
  before POST.

## Proof
- `nix build .#frontend` green (and `just build`/the frontend check).
- Browser smoke (Playwright or manual): select the mode, add two rows
  (e.g. Core Development + Network Compliance), fill amounts + wallet +
  metadata, submit against a running API, see the unsigned-tx render.
  Record evidence in WIP.md.

## Notes
- RED-skip is expected (no frontend unit harness) — log the rationale in
  WIP.md; proof = build + browser smoke.
- One bisect-safe commit if feasible; if the render + state + request
  split cleanly into two commits, that's fine — keep each building.
