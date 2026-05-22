# Plan — 212 reorganize phase-2 (scopes-NFT reference)

## Trade-offs

- **Scope discipline**: this is a missing reference input on an
  existing intent shape, not a new feature. The fix is additive
  (new field, new reference line, new JSON key, new schema field, new
  test). No semantic change to existing fields.
- **Bisect-safety**: the fix is one vertical slice. RED tests fail
  before the field is added (intent parser rejects malformed; golden
  script context misses the scopes-NFT reference). GREEN adds the
  field and threads it through the wizard, intent JSON, schema,
  builder, and golden expectations in one commit.
- **Live-boundary proof**: unit + golden suites can pass while the
  validator still rejects, because the golden suite uses a frozen
  ChainContext. The acceptance bar is the **live devnet smoke** at
  `just devnet-cli-smoke --phase reorganize`, which talks to a real
  node and runs the Plutus evaluator end-to-end. That smoke is the
  load-bearing check; unit + golden are regression nets.

## Slice plan

### S1 — Thread `scopesDeployedAt` through reorganize intent + program (one bisect-safe commit)

**Owned files** (full list — used as the dispatch brief's owned-files set):

- `lib/Amaru/Treasury/Tx/Reorganize.hs`
- `lib/Amaru/Treasury/Build/Reorganize.hs`
- `lib/Amaru/Treasury/IntentJSON.hs`
- `lib/Amaru/Treasury/IntentJSON/Schema.hs`
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`
- `test/unit/Amaru/Treasury/IntentJSONSpec.hs`
- `test/golden/ReorganizeGoldenSpec.hs`
- any new golden fixtures under `test/golden/fixtures/reorganize/`
  required to re-pin the script context (regenerate via existing
  `nix develop -c just golden-accept` if a sibling recipe exists; if
  not, hand-edit the new expected line).

**RED** (must be observed failing first):

- Add a roundtrip + decoder test in `IntentJSONSpec.hs` that asserts
  the `ReorganizeInputs` JSON contains `scopesDeployedAt` and that an
  intent missing the field fails to parse with a precise error.
- Extend `ReorganizeGoldenSpec.hs` so the script-context predicate
  for the reorganize tx asserts the scopes-NFT reference UTxO is
  attached to `txInfoReferenceInputs`. On `origin/main`, this fails.

**GREEN**:

- Add `rgiScopesDeployedAt :: !TxIn` to `ReorganizeIntent`
  (`Reorganize.hs`); emit `reference (rgiScopesDeployedAt intent)` in
  `reorganizeProgram`.
- Extend `Build/Reorganize.hs` `refInputs` with the new field so
  resolved UTxOs are pulled into the build context.
- Add `riScopesDeployedAt :: !TxIn` to `ReorganizeInputs`; parse from
  / emit the `scopesDeployedAt` JSON key; update the schema in
  `IntentJSON/Schema.hs`; thread through `intentToReorganize` / the
  translation site.
- Update `ReorganizeWizard.hs` so the wizard reads
  `Metadata.scope_owners` (already parsed; see
  `lib/Amaru/Treasury/Metadata.hs:87`) and writes
  `scopesDeployedAt` into the intent JSON. This mirrors the existing
  `Tx/SwapWizard.hs` (`SwapWizard.hs:404`) and the disburse wizard
  pattern.
- Adjust golden fixtures if any; ensure unit suite (`just unit`) and
  golden suite (`just golden`) are green.

**Proof commands**:

- Unit RED: `nix develop -c just unit "Reorganize"` and `... "IntentJSON"`
- Golden: `nix develop -c just golden`
- Gate: `./gate.sh`

**Commit shape**:

```
fix(reorganize): include scopes-NFT reference UTxO so phase-2 succeeds

Tasks: T001, T002
```

### S2 — Live-boundary devnet smoke proof (orchestrator-owned)

After S1 lands, the orchestrator runs:

```bash
nix develop -c just devnet-cli-smoke \
  --phase reorganize \
  --run-dir runs/devnet-cli/<stamp>
```

against a fresh local devnet, archives the run dir, and records the
build.log + submission outcome in the PR body. This is the
load-bearing live-boundary proof for the acceptance criteria. The
orchestrator does not commit run-dir artifacts (they are
operator-facing evidence, not source). If the smoke fails for an
unrelated reason (devnet not up, fuel exhausted, etc.) the
orchestrator surfaces it on the PR and re-runs; if it fails for a
related reason, S1 is reopened.

### S3 — Drop gate.sh, mark ready (orchestrator-owned)

`git rm gate.sh`, push, `gh pr ready 214`.

## Live-boundary diagnostic

For S1: *"What system boundary does this exercise that the unit suite
cannot?"* — the Plutus phase-2 evaluator running inside a real
cardano-node against a deployed Aiken validator. Unit + golden cover
construction shape; only the devnet smoke proves the validator
accepts the constructed transaction.

## Risks

- The new `scopesDeployedAt` outref differs by network. The wizard
  must read it from the on-disk metadata, not embed a constant.
  Disburse's `--network devnet` path is the reference (see
  `lib/Amaru/Treasury/Cli/DisburseWizard.hs` for the load pattern).
- Golden fixtures under `test/golden/fixtures/reorganize/` may need
  regeneration. If a `just golden-accept` exists, the worker uses
  it; if not, the worker hand-edits and the navigator verifies the
  diff is mechanical (only the new reference UTxO line changes).
- The intent JSON schema is consumed downstream by `tx-build`. A new
  required field is a **breaking change** to any user with an
  in-flight reorganize intent on disk. Acceptable: this PR fixes a
  failed-to-submit chain; there are no in-flight reorganize intents
  in the wild that would survive a phase-2 failure.

## Out of scope (re-asserted)

- Upstream Aiken changes.
- Redeemer shape changes (already correct).
- New smoke phases or new CLI surfaces.
- Operator-facing asciinema (owned by #188).
