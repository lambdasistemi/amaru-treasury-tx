# Plan — Chain horizon governs validity-upper-bound

Spec: [spec.md](spec.md). Issue: [#88](https://github.com/lambdasistemi/amaru-treasury-tx/issues/88). PR: [#89](https://github.com/lambdasistemi/amaru-treasury-tx/pull/89).

## Design Decisions

### D1. Resolver computes the slot; pure translator just reads it.

`ResolverEnv` in each wizard exposes `reEnvComputeUpperBound :: ValidityChoice -> m (Either HorizonError SlotNo)`. The resolver invokes it once per wizard run, stores the result in `WizardEnv.weUpperBoundSlot`, and propagates `HorizonError` as a wizard-typed error. The pure translator (`wizardToTreasuryIntent`) reads `weUpperBoundSlot` directly — no `tip + N*3600` arithmetic in pure code.

**Why**: keeps the pure layer pure, lets unit tests pin a concrete `upperBoundSlot` instead of replaying horizon math, and matches how `weTreasurySelection` / `weWalletSelection` are already shaped (resolver-side precomputation, pure consumption).

### D2. `wqValidityHours :: Maybe Word16`.

`Nothing` ≡ AutoLongest, `Just 0` ≡ reject, `Just n` (n ≥ 1) ≡ `ExactlyHours n`. `Word16` matches the type used by `cardano-node-clients`' `Validity.ValidityChoice`, avoiding a conversion between layers.

**Trade-off considered**: a single `ValidityChoice` field in answers. Rejected because the JSON shape stays simpler with `Maybe Word16` (omit the key for AutoLongest), and we don't expose `MaxHours` at the wizard yet (out of scope per spec).

### D3. Single new error constructor `WizardValidityOvershoot HorizonError`.

Wraps the helper's error without re-shaping it. The wizard's typed-error tracer renders a single one-line message including all four fields.

### D4. CLI `--validity-hours` is `option auto (long ...) <|> pure Nothing` rather than a positional.

`optparse-applicative`'s `optional (option auto ...)` is the idiomatic shape and keeps shell-pipe ergonomics. Help text drops the `1..168` window; says `"Optional. When omitted, the chain's current horizon is used."`.

### D5. Wizard tests pin `upperBoundSlot` directly; fixture JSON renamed.

The golden `env.json` fixtures replace `currentTip` with `upperBoundSlot`. The golden `expected.intent.json` keeps the same `validityUpperBoundSlot` value, because we pin the fixture's `upperBoundSlot` to match the *prior* fixture's computed bound (`186342942 + 6 * 3600 = 186364542` for swap-wizard). Result: zero behavior-visible churn in the goldens; only the intermediate JSON shape changes.

### D6. Gate.

`llm/reviews/local-feat-088-validity-hours-week/gate.sh` runs `nix develop -c just ci`. The boundary smoke is the existing `app/horizon-probe/Main.hs` against the live mainnet socket; we exercise it manually before pushing the final slice, capture the output in [PR #89](https://github.com/lambdasistemi/amaru-treasury-tx/pull/89)'s description.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Three wizards' fixtures, JSON parsers, and error types all need touching; large surface to keep bisect-safe. | One vertical slice per wizard (S2, S3, S4). Each slice is internally consistent — env field renamed, answers field reshaped, CLI parser made optional, error constructor added, fixtures rebuilt, tests pass — all in one commit. |
| Fixture JSON renames break tests that load `env.json` with `(.: "currentTip")`. | Same slice rewrites the JSON parser, the fixture, and any test reading it. Tests fail compile if not. |
| `swap-quote` uses `sqarValidityHours :: Integer` (not the wizard answer type); easy to forget. | S2 (swap slice) also updates `swap-quote` since they share `Cli/SwapCommon` plumbing. |
| The CLI's positional/named conventions are inconsistent across the four subcommands. | Each CLI parser keeps its existing flag layout, only the cardinality (required → optional) and help text change. |
| `cabal.project` already has the pin at `1dc1b87` (chore commit `897c1dd`). The S1 slice is therefore empty. | Fold S1 into S0 (docs commit also bumps the pin). Skip S1. |

## Slice Plan (vertical commits)

Reshape the current three commits on `feat/088-validity-hours-week` into the slices below by `git reset --soft origin/main` + re-commit. Force-push.

### S0 — Spec / plan / tasks + cardano-node-clients pin bump

- **Type**: docs + chore (no behavior change).
- **Files**:
  - `specs/088-horizon-validity-rule/{spec,plan,tasks}.md` (new).
  - `llm/reviews/local-feat-088-validity-hours-week/gate.sh` (new).
  - `cabal.project` — pin to `1dc1b8726bdaf099361620cba3b07751fd326a8c` (already present).
- **Commit message**: `docs(088): spec, plan, tasks; bump cardano-node-clients`.

### S1 — Swap wizard adopts horizon rule

- **Type**: feat. RED tests + GREEN impl folded into one bisect-safe commit per the pr-skill contract.
- **Diff**:
  - `lib/Amaru/Treasury/Tx/SwapWizard.hs`: `wqValidityHours :: Maybe Word16`; `weCurrentTip` → `weUpperBoundSlot`; resolver call goes through `reEnvComputeUpperBound`; `WizardValidityHoursOutOfRange` replaced by `WizardValidityHoursZero` + `WizardValidityOvershoot HorizonError`; static `h > 168` guard deleted; pure translator reads `weUpperBoundSlot` directly.
  - `lib/Amaru/Treasury/Cli/SwapWizard.hs`, `lib/Amaru/Treasury/Cli/SwapQuote.hs`: `--validity-hours` becomes `optional (option auto ...)`; help text rewritten.
  - `lib/Amaru/Treasury/Tx/SwapQuote.hs`: `sqarValidityHours :: Maybe Integer`; quote flows through the optional path.
  - `test/fixtures/swap-wizard/env.json`: drop `currentTip`, add `upperBoundSlot` pinned to `186364542`. `answers.json`: drop `validityHours` (or set to `null`).
  - `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: replaces "rejects hours > 168 / accepts 168" pair with new tests:
    - "accepts hours absent (AutoLongest)" — `wqValidityHours = Nothing` produces intent with the resolver-supplied `upperBoundSlot`.
    - "accepts a specific hours value within horizon" — `Just 6` round-trips.
    - "rejects hours = 0" — typed error.
    - "rejects overshoot" — resolver-injected `HorizonError` surfaces as `WizardValidityOvershoot`.
  - Existing test "computes validityUpperBoundSlot from tip + slotsPerHour * hours" rewrites to assert `weUpperBoundSlot` is the source.
  - `docs/quickstart.md`, `docs/swap.md`: optional flag, new error message.
- **Bisect-safe**: yes — wizard, CLI, fixture, tests, and docs all flip together.
- **Commit message**: `feat(088): swap-wizard validity follows chain horizon`.

### S2 — Disburse wizard adopts horizon rule

- Same pattern as S1 for `Amaru.Treasury.Tx.DisburseWizard` + `Cli.DisburseWizard`. Fixture `test/fixtures/disburse-wizard/env.json` rewritten.
- **Commit message**: `feat(088): disburse-wizard validity follows chain horizon`.

### S3 — Withdraw wizard adopts horizon rule

- Same for `Amaru.Treasury.Tx.WithdrawWizard` + `Cli.WithdrawWizard`. Fixture under `test/fixtures/withdraw/`.
- **Commit message**: `feat(088): withdraw-wizard validity follows chain horizon`.

### S4 — `app/horizon-probe/Main.hs` (verification artifact)

- Already on the branch (commit `90de888`). Will be re-committed cleanly. No production code change.
- **Commit message**: `chore(088): horizon-probe exe (live boundary smoke evidence)`.

## Reshape Procedure

```bash
cd /code/amaru-treasury-tx-issue-88
git fetch origin
git reset --soft origin/main       # all current changes staged
# Working tree carries: pin bump, probe, old cap-raise diffs.
# Unstage everything; re-stage per slice; commit.
git restore --staged .
# S0:
git add specs/088-horizon-validity-rule/ \
        llm/reviews/local-feat-088-validity-hours-week/ \
        cabal.project
git commit -m "docs(088): …"
# S1: implement, then:
git add lib/Amaru/Treasury/Tx/SwapWizard.hs \
        lib/Amaru/Treasury/Tx/SwapQuote.hs \
        lib/Amaru/Treasury/Cli/SwapWizard.hs \
        lib/Amaru/Treasury/Cli/SwapQuote.hs \
        test/fixtures/swap-wizard/ \
        test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs \
        docs/swap.md docs/quickstart.md
git commit -m "feat(088): …"
# S2, S3, S4 similarly.
git push --force-with-lease
```

## Gate

`specs/088-horizon-validity-rule/gate.sh` (this repo gitignores `llm/`, so review artefacts live under `specs/`):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nix develop --quiet -c just ci
```

Live boundary smoke before final push:

```bash
CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket \
  cabal run -v0 -O0 exe:amaru-treasury-tx -- \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-wizard --wallet-addr addr1q802wxt6c… \
      --metadata /code/metadata-mainnet.json --scope network_compliance \
      --usdm 100000 --split 33 --min-rate 0.245 \
      --description … --justification … --destination-label …
      # NO --validity-hours; expect AutoLongest path
```

and a second run with `--validity-hours 120` (current epoch → overshoot expected; assert non-zero exit with a single-line typed error).
