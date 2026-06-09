# Plan — Unify contingency disburse under disburse-by-scope (#334)

Spec = issue #334 AC. Follow-up to epic #325. Two independent slices
(Haskell CLI + PureScript UI); on-chain behavior + intent.json unchanged;
HTTP endpoints unchanged (UI routes by scope).

## Slice A — CLI: disburse-wizard --scope contingency --to <scope>:<ada>
Fold the `contingency-disburse-wizard` logic into `disburse-wizard`:
- When `--scope contingency`: accept repeatable `--to <scope>:<ada>`
  (owned-scope destinations, ADA), reuse `runContingencyDisburse`'s
  derivation (verify Contingency ∪ dests, resolve scope addresses, fixed
  rationale), produce the SAME intent.json. Reject a beneficiary-addr /
  missing `--to` with a clear message.
- When `--scope <other>`: unchanged single beneficiary-address disburse.
- Remove the `contingency-disburse-wizard` subcommand (or hidden alias);
  `CmdContingencyDisburse` path folds into the disburse command.
- Files: `lib/Amaru/Treasury/Cli.hs`, `lib/Amaru/Treasury/Cli/DisburseWizard.hs`,
  `app/amaru-treasury-tx/Main.hs`, parser/input-control specs.
- Proof: parser + wizard unit tests (contingency-by-scope, rejections);
  `just ci`; intent.json for `--scope contingency --to a:.. --to b:..`
  matches the old `contingency-disburse-wizard` output.

## Slice B — UI: 3 modes, Disburse form by source scope
- Remove `ModeContingencyDisburse` from `TxMode` (3 modes). Build
  exhaustiveness drives the ~15 case sites to fold into ModeDisburse.
- Disburse form branches on `st.scope`: Contingency → destination-scope
  rows (existing `contingencyDestinations` + `contingencyDisburseRequestJson`)
  → POST `/v1/build/contingency-disburse`; else beneficiary address →
  `/v1/build/disburse`.
- `scopePicker` is mode-aware: Swap/Reorganize → `ownedScopes` (exclude
  Contingency); Disburse → `allScopes`.
- Title/labels stay coherent (Disburse + Contingency → "contingency
  disburse").
- Files: `frontend/src/OperatePage.purs`.
- Proof: `nix build .#frontend`; browser smoke (Disburse+Contingency rows;
  Disburse+other address; Swap/Reorganize omit Contingency).
