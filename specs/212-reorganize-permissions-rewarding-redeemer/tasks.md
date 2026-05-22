# Tasks — 212 reorganize phase-2 (scopes-NFT reference)

Owning doc: `specs/212-reorganize-permissions-rewarding-redeemer/{spec,plan}.md`.

## What this PR delivers

The phase-2 redeemer/reference parity fix only. The named #212 symptom —
the Aiken permissions rewarding-script returning `error` — is gone. The
wider devnet-smoke end-to-end pass and the mainnet operator path are
tracked separately and are out of scope here:

- [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217)
  — wizard UTxO selection must exclude script-deploy outrefs (phase-1
  `BabbageNonDisjointRefInputs` surfaced by the live smoke once the
  phase-2 error was gone).
- [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218)
  — lift the `ReorganizeNonDevnetNetwork` guard so the operator can
  produce a real mainnet reorganize transaction (the actual exit
  criterion for epic #189).

## Bootstrap

- [X] T000 — Bootstrap worktree + `gate.sh` + draft PR. Commit
  `3d630ea3`.

## S1 — Thread `scopesDeployedAt` through reorganize

- [X] T001 — RED: unit + golden tests assert `ReorganizeInputs` JSON
  carries `scopesDeployedAt` and the reorganize tx's
  `txInfoReferenceInputs` include the scopes-NFT UTxO. Closed in
  commit `d8fdf590`.
- [X] T002 — GREEN: `rgiScopesDeployedAt` / `riScopesDeployedAt`
  fields, 4th `reference` line in `reorganizeProgram`,
  `Build/Reorganize.hs` `refInputs` extended, JSON parser/encoder
  + schema updated, wizard reads `metadata.scope_owners`. Golden
  fixtures regenerated. `./gate.sh` green. Closed in commit
  `d8fdf590`.

## S2 — Phase-2 evaluator proof (orchestrator-owned)

- [X] T003 — Verified phase-2 path: the Aiken permissions rewarding
  script no longer returns `error` on the constructed transaction.
  Run dir
  `runs/devnet-cli/212-20260522T122338Z/phases/reorganize/build.log`
  shows the build now reaches phase-1 (where it fails on the
  unrelated wizard UTxO-selection bug filed as
  [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217)).
  Mainnet end-to-end validation deferred to
  [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218).

## S3 — Finalize (orchestrator-owned)

- [X] T004 — Finalization audit, `git rm gate.sh`,
  `chore: drop gate.sh (ready for review)`, push, mark PR ready.

## Cross-references

- Validator: `/code/amaru-treasury/validators/permissions.ak:46-57`
- Scopes lookup: `/code/amaru-treasury/lib/scope.ak:76-93`
- Upstream bash reference list:
  `/code/amaru-treasury/journal/2026/lib/build_transaction.sh:17-18`
  + `load_permissions_config.sh:6`
- Disburse precedent (already has scopes ref):
  `lib/Amaru/Treasury/Tx/Disburse.hs:84`,
  `Disburse.hs:171`
- Reorganize sites edited in `d8fdf590`:
  `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`,
  `lib/Amaru/Treasury/IntentJSON.hs`,
  `lib/Amaru/Treasury/IntentJSON/Schema.hs`,
  `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs`,
  `test/unit/Amaru/Treasury/IntentJSONSpec.hs`,
  `test/golden/ReorganizeGoldenSpec.hs`,
  `test/fixtures/reorganize-core/`.
