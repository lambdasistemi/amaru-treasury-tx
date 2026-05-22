# Tasks — 212 reorganize phase-2 (scopes-NFT reference)

Owning doc: `specs/212-reorganize-permissions-rewarding-redeemer/{spec,plan}.md`.

## Bootstrap

- [X] T000 — Bootstrap worktree + `gate.sh` + draft PR. (Commit
  `3d630ea3`.)

## S1 — Thread `scopesDeployedAt` through reorganize

Single bisect-safe slice. Driver+navigator pair. RED → GREEN in one
amended commit. Commit subject:

```
fix(reorganize): include scopes-NFT reference UTxO so phase-2 succeeds
```

Tasks closed by this commit: T001, T002.

- [X] T001 — RED: add unit + golden tests asserting
  `ReorganizeInputs` JSON carries `scopesDeployedAt` and the
  reorganize tx's `txInfoReferenceInputs` include the scopes-NFT
  UTxO. Tests must fail on `origin/main` before T002 lands.
- [X] T002 — GREEN: add `rgiScopesDeployedAt`/`riScopesDeployedAt`
  fields; emit `reference` line in `reorganizeProgram`; include in
  `Build/Reorganize.hs` `refInputs`; parse/emit JSON; update schema;
  thread `metadata.scope_owners` through `ReorganizeWizard.hs`;
  regenerate or hand-edit golden fixtures. RED tests pass at HEAD.
  `./gate.sh` green.

## S2 — Live-boundary devnet smoke (orchestrator-owned)

- [ ] T003 — Run `nix develop -c just devnet-cli-smoke --phase
  reorganize --run-dir runs/devnet-cli/<stamp>` against a fresh local
  devnet. Verify phase-2 evaluation passes and the merged treasury
  UTxO is confirmed on-chain. Record evidence on the PR body.

## S3 — Finalize (orchestrator-owned)

- [ ] T004 — Finalization audit
  (`finalization_audit 214 specs/212-reorganize-permissions-rewarding-redeemer/tasks.md`);
  `git rm gate.sh`; `chore: drop gate.sh (ready for review)`; push;
  `gh pr ready 214`.

## Cross-references

- Validator: `/code/amaru-treasury/validators/permissions.ak:46-57`
- Scopes lookup: `/code/amaru-treasury/lib/scope.ak:76-93`
- Upstream bash reference list:
  `/code/amaru-treasury/journal/2026/lib/build_transaction.sh:17-18`
  + `load_permissions_config.sh:6`
- Disburse precedent (already has scopes ref):
  `lib/Amaru/Treasury/Tx/Disburse.hs:84`,
  `Disburse.hs:171`
- Reorganize sites to edit:
  `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/Reorganize.hs`,
  `lib/Amaru/Treasury/IntentJSON.hs:559-665`,
  `lib/Amaru/Treasury/IntentJSON/Schema.hs:182,205`,
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`,
  `test/unit/Amaru/Treasury/IntentJSONSpec.hs:525`,
  `test/golden/ReorganizeGoldenSpec.hs`.
