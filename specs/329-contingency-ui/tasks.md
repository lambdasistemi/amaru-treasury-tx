# Tasks — Operate UI: Contingency Disburse mode (#329)

## Slice A — Contingency Disburse mode end-to-end

- [ ] T329-SA1 Add `ModeContingencyDisburse` to `TxMode`, the mode
      selector button, title/label, and `modeToString`/`stringToMode`;
      handle every exhaustive `case … of TxMode` site so the bundle
      compiles.
- [ ] T329-SA2 State + form: `contingencyDestinations` rows (scope
      selector over the four owned scopes + ADA input, add/remove), plus
      wallet/metadata/validity/description/justification fields; no unit
      selector. Client-side guard rejects empty list / Contingency scope.
- [ ] T329-SA3 `contingencyDisburseRequestJson` + `postBuild
      "/v1/build/contingency-disburse"`; render the
      `DisburseBuildResponse` success/failure surface as disburse does.
- [ ] T329-SA4 `nix build .#frontend` green; browser smoke: add two
      destination rows, submit against a running API, unsigned-tx
      renders. Record evidence in WIP.md (RED-skip rationale: no frontend
      unit harness).
