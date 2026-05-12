# Tasks — Chain horizon governs validity-upper-bound

Spec: [spec.md](spec.md) · Plan: [plan.md](plan.md) · Issue: [#88](https://github.com/lambdasistemi/amaru-treasury-tx/issues/88) · PR: [#89](https://github.com/lambdasistemi/amaru-treasury-tx/pull/89).

## S0 — Spec / plan / tasks + pin bump *(one reviewed commit, docs+chore)*

| Task | Type | Output |
|---|---|---|
| T0.1 | docs | `specs/088-horizon-validity-rule/{spec,plan,tasks}.md`. |
| T0.2 | docs | `llm/reviews/local-feat-088-validity-hours-week/gate.sh` (executable, runs `nix develop -c just ci`). |
| T0.3 | chore | `cabal.project` pin at `1dc1b8726bdaf099361620cba3b07751fd326a8c` (already present in the current branch — rolled into S0 by the reshape). |

**Commit**: `docs(088): spec, plan, tasks; bump cardano-node-clients to merged main`. Non-behavioral.

## S1 — Swap wizard adopts horizon rule *(one reviewed commit)*

| Task | Type | Folds with | Output |
|---|---|---|---|
| T1.1 | RED | T1.2 | Rewrite `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: replace "accepts validity hours = 168 / rejects > 168 / rejects = 0" trio with: (a) "wqValidityHours = Nothing emits the env-supplied upperBoundSlot"; (b) "wqValidityHours = Just 6 with horizon ≥ 6 h emits tip + 6 h via env-supplied upperBoundSlot"; (c) "wqValidityHours = Just 0 yields WizardValidityHoursZero"; (d) "resolver-injected HorizonError surfaces as WizardValidityOvershoot". Update fixture-loading "computes validityUpperBoundSlot ..." assertion to read from `weUpperBoundSlot`. |
| T1.2 | RED | T1.3 | Update fixtures: `test/fixtures/swap-wizard/env.json` drops `currentTip`, adds `upperBoundSlot: 186364542`; `answers.json` drops `validityHours` (Nothing case) OR pins it to `6` (existing case — pick one and document). |
| T1.3 | GREEN | T1.1, T1.2 | `lib/Amaru/Treasury/Tx/SwapWizard.hs`: `wqValidityHours :: Maybe Word16`; `WizardEnv` field `weCurrentTip :: Word64` → `weUpperBoundSlot :: SlotNo`; `WizardError` gains `WizardValidityHoursZero` + `WizardValidityOvershoot HorizonError`, drops `WizardValidityHoursOutOfRange`; pure `wizardToTreasuryIntent` reads `weUpperBoundSlot` directly. |
| T1.4 | GREEN | T1.3 | `ResolverEnv` field `reEnvCurrentTip :: m Word64` → `reEnvComputeUpperBound :: ValidityChoice -> m (Either HorizonError SlotNo)`. Resolver `resolveWizardEnv` derives a `ValidityChoice` from `wqValidityHours` (Nothing → AutoLongest; Just 0 → bail with WizardValidityHoursZero; Just n → ExactlyHours n), calls it, and maps the Left into `WizardValidityOvershoot`. |
| T1.5 | GREEN | T1.3 | `lib/Amaru/Treasury/Cli/SwapWizard.hs`: `--validity-hours HOURS` becomes `optional (option auto ...)`; help text `"Optional. Omit to use the chain's current horizon."`. Same in `lib/Amaru/Treasury/Cli/SwapQuote.hs`. |
| T1.6 | GREEN | T1.3 | `lib/Amaru/Treasury/Tx/SwapQuote.hs`: `sqarValidityHours :: Maybe Integer`; threads the optional value. |
| T1.7 | GREEN | T1.4 | `app/amaru-treasury-tx/Main.hs` (or wherever the live resolver is wired) implements `reEnvComputeUpperBound` over `Provider.queryUpperBoundSlot`. Same plumbing point that previously implemented `reEnvCurrentTip`. |
| T1.8 | docs | T1.3..T1.7 | `docs/swap.md`, `docs/quickstart.md`: optional flag; describe the typed-overshoot error. |

**Reviewed commit**: `feat(088): swap-wizard validity follows chain horizon`. RED tests + GREEN impl in one commit.

## S2 — Disburse wizard adopts horizon rule *(one reviewed commit)*

| Task | Type | Output |
|---|---|---|
| T2.1 | RED+GREEN | Mirror S1 for `Amaru.Treasury.Tx.DisburseWizard` + `Amaru.Treasury.Cli.DisburseWizard`. New fixture and tests. Live resolver point updated. |
| T2.2 | docs | `docs/withdraw.md` doesn't apply; if a separate `docs/disburse.md` exists, update it. Otherwise update the disburse references inside `docs/quickstart.md`. |

**Reviewed commit**: `feat(088): disburse-wizard validity follows chain horizon`.

## S3 — Withdraw wizard adopts horizon rule *(one reviewed commit)*

| Task | Type | Output |
|---|---|---|
| T3.1 | RED+GREEN | Mirror S1 for `Amaru.Treasury.Tx.WithdrawWizard` + `Amaru.Treasury.Cli.WithdrawWizard`. New fixture and tests. Live resolver point updated. |
| T3.2 | docs | `docs/withdraw.md`. |

**Reviewed commit**: `feat(088): withdraw-wizard validity follows chain horizon`.

## S4 — Horizon-probe artefact *(one reviewed commit, non-behavioral)*

| Task | Type | Output |
|---|---|---|
| T4.1 | chore | `app/horizon-probe/Main.hs` + cabal stanza. Already in the branch as commit `90de888`; reshape re-stages it as a clean final commit. |

**Reviewed commit**: `chore(088): horizon-probe exe (live boundary smoke evidence)`.

## Folding & bisect-safety summary

Every behavior-changing slice (S1, S2, S3) bundles its RED tests, GREEN impl, fixture updates, CLI parser change, error-type changes, and docs updates into one commit. S0 and S4 are docs/chore only.

## Reshape order

```
S0 — docs(088): spec, plan, tasks; bump cardano-node-clients to merged main
S1 — feat(088): swap-wizard validity follows chain horizon
S2 — feat(088): disburse-wizard validity follows chain horizon
S3 — feat(088): withdraw-wizard validity follows chain horizon
S4 — chore(088): horizon-probe exe (live boundary smoke evidence)
```

Current branch state (`feat/088-validity-hours-week`):

```
897c1dd chore(088): repin cardano-node-clients to main after PR #134 merged
90de888 verify(088): horizon-probe + pin cardano-node-clients PR #134
b820c84 feat: raise validity-hours cap from 48 to 168 (1 week)
```

The reshape (`git reset --soft origin/main` then re-commit) replaces these three with the five-slice ordering above. Force-push with `--force-with-lease`.
