# Implementation Plan — `187-reorganize-wizard-runner`

**Feature Branch**: `187-reorganize-wizard-runner`
**Created**: 2026-05-22
**Status**: Draft (Plan phase — Q-002-plan-ready)
**GitHub Issue**: [#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187)
**Pull Request**: [#198](https://github.com/lambdasistemi/amaru-treasury-tx/pull/198) (draft)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
**Spec**: [`spec.md`](./spec.md) — Q-001 approved at A1/B1/C1/D1/E1
  (all recommended defaults; see `A-001-spec-ready.md`).
**Companion artifacts**:

- [`research.md`](./research.md) — design decisions + alternatives.
- [`data-model.md`](./data-model.md) — typed shapes
  (`ReorganizeResolverInput`, `ReorganizeResolverEnv m`,
  `ReorganizeEnv`, extended `ReorganizeError`).
- [`contracts/`](./contracts/) — resolver contract, intent-JSON
  contract, exit-code contract.
- [`quickstart.md`](./quickstart.md) — operator's-eye view of the
  command this slice ships.

> This is the **runner-body + DevNet guard** slice (epic #189 child
> 3 of 5). #185 shipped the library-core build path; #186 shipped
> the CLI parser scaffold + stub runner. After this slice, an
> operator running `amaru-treasury-tx reorganize-wizard --network
> devnet …` against a healthy DevNet observes a bare
> `SomeTreasuryIntent` JSON at `--out`, ready for `tx-build
> --intent`. Sibling children #87 (DevNet smoke) and #188 (docs +
> asciinema cast) are blocked on this slice landing first.

## Ownership split

| Role | Owns |
|---|---|
| Orchestrator (attx-187) | `spec.md`, `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`, `gate.sh`, PR metadata, slice briefs, vertical-slice review, finalization audit, post-merge cleanup. |
| Slice executor (one paired driver+navigator per slice) | Owned files listed per slice below; produces exactly one bisect-safe commit per run with a `Tasks:` trailer. Does not push. |

## Technical Context

- **Language/Version**: Haskell, GHC 9.6+ (matches
  `cardano-node-clients`).
- **Primary Dependencies**:
  - `Amaru.Treasury.Metadata` for `readMetadataFile` (already on
    `main`).
  - `Amaru.Treasury.Backend.N2C` for `withLocalNodeBackend` (already
    on `main`).
  - `Cardano.Node.Client.Provider` for `queryUpperBoundSlot` + flat
    UTxO queries (already a transitive dep via
    `cardano-node-clients`).
  - `Amaru.Treasury.IntentJSON` for `encodeSomeTreasuryIntent` +
    `decodeTreasuryIntent` (already on `main`).
  - `Amaru.Treasury.Tx.SwapWizard.selectWallet` for the wallet-UTxO
    selection helper (already on `main`).
  - `Amaru.Treasury.Cli.Common` for `GlobalOpts`,
    `resolveNetworkName`, `queryFlat` (already on `main`; #186 wired
    `Cli/ReorganizeWizard.hs` against these).
- **Storage**: filesystem only — `--metadata` (input),
  `--out` `*.intent.json` (output).
- **Testing**: Hspec, mock-driven `ReorganizeResolverEnv` (no live
  node; mirrors `StakeRewardInitResolverEnv`).
- **Target Platform**: Linux server (DevNet). Mainnet/preprod
  rejected at the DevNet guard.
- **Project Type**: CLI subcommand under `amaru-treasury-tx`.
- **Performance Goals**: not exercised in this slice; the runner is
  per-invocation human-operator workflow (one tx at a time).
- **Constraints**: no new dependencies, no `cardano-api` (per the
  parent-epic invariant), no signing, no submission.
- **Scale/Scope**: one operator command surface — extends the
  behavior of the existing `reorganize-wizard` subcommand from
  "parses + TODO" to "parses + produces intent JSON".

## Constitution Check

| Principle | Status |
|---|---|
| **I. Faithful port of bash recipes** | ✅ This slice ports the `load_metadata` / `build_signers` / `resolve_fuel` / `select_treasury_utxos` / `compute_validity_period` phases of `reorganize.sh` 1:1. See [`research.md` §1](./research.md#1-upstream-parity-mapping). |
| **II. Pure builders, impure shell** | ✅ The translator (`reorganizeToIntent`) is pure; the resolver (`resolveReorganize`) is `Monad m =>` and tested with `Identity`; the live `runReorganizeWizardEither` is the impure shell. |
| **III. Pluggable data source, local-node default** | ✅ Live wiring uses `withLocalNodeBackend`; the resolver is mock-driven for tests. |
| **IV. Build, never sign or submit** | ✅ The runner produces a `SomeTreasuryIntent` JSON; signing/submission are out of scope. |
| **V. Test-first with golden CBOR fixtures** | ✅ The translator's golden coverage rides on the library codec's existing `SReorganize` round-trip golden (#185). Runner-level tests cover the resolver + translator via mock env; the unit suite uses `Eq`-based assertions. |
| **VI. Hackage-ready Haskell** | ✅ New code carries Haddock, fourmolu 70-col, `-Werror`. No new dependencies. |
| **VII. Label-1694 metadata: bash parity** | ✅ The rationale block (`RationaleJSON`) reuses the existing event enum (`reorganize`) and bash-parity body shape. No `@context` / `event` changes. |

**Gate verdict**: PASS. No violations; the Complexity Tracking
section below is empty.

## Q-001 verdicts (epic-owner-approved at A-001-spec-ready)

| Question | Verdict | Plan-time outcome |
|---|---|---|
| **A**: Registry-source-of-truth flag | A1 | `--metadata` (existing, sibling-mirrored). No new flag; reuse `Amaru.Treasury.Metadata.readMetadataFile`. |
| **B**: `permissionsRewardAccount` derivation | B1 | Derived inside `reorganizeToIntent` from `smPermissions.srHash` + the resolved network magic. The helper is co-located in `Tx/ReorganizeWizard.hs` (small, one-call site). |
| **C**: Fuel-UTxO source | C1 | Operator-typed `--funding-seed-txin` is baked into `ReorganizeInputs.walletUtxo` verbatim; wallet-addr chain query is informational only (its shortfall surfaces `ReorganizeWalletShortfall`). |
| **D**: Treasury-UTxO ordering | D1 | Selected UTxOs are sorted by `(TxId, TxIx)` ascending before construction. Deterministic; fixture-stable. |
| **E**: "Compress until full" cap | E1 | Take all UTxOs the treasury-address query returns. The library-core build path (#185) surfaces the body-size error if the result is too big. The iterative cap is a deferred follow-up (no new ticket filed in this slice). |

No spec amendments required.

## Vertical slice plan (bisect-safe)

The work decomposes into **two implementation slices** plus the
mandatory `chore: drop gate.sh` finalization commit. Each
implementation slice is one paired driver+navigator run producing
exactly one bisect-safe commit. Every commit compiles; every
commit's `./gate.sh` is green at HEAD.

### S1 — extend `Tx/ReorganizeWizard.hs` with resolver + translator + spec (RED → GREEN)

**Goal:** ship the **library half** of the runner body — the new
types (`ReorganizeResolverInput`, `ReorganizeResolverEnv m`,
`ReorganizeEnv`), the extended `ReorganizeError` variants, the
pure-monadic `resolveReorganize`, the pure translator
`reorganizeToIntent`, and the runner spec covering User Stories 1,
2, 3, 5 via mock resolver env. The stub `runReorganizeWizardEither`
in `Cli/ReorganizeWizard.hs` is **not** touched in this slice; the
`ReorganizeTodoSliceC` variant remains, the existing parser spec
keeps passing, and the cabal `library` half is complete.

**Owned files (S1 only):**

- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` — extend with the
  new resolver/translator types + functions; extend
  `ReorganizeError` with the runner-body variants
  (`ReorganizeMetadataReadError`,
  `ReorganizeScopeNotInMetadata`, `ReorganizeScopeOwnerMissing`,
  `ReorganizeInsufficientTreasuryUtxos`,
  `ReorganizeWalletShortfall`, `ReorganizeValidityHoursZero`,
  `ReorganizeValidityOvershoot`, plus the ledger-field-parse
  variants — see [`data-model.md` §2](./data-model.md#2-reorganizeerror)).
  Keep `ReorganizeTodoSliceC` in the sum (S2 removes it).
- `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` (NEW) —
  Hspec spec covering User Stories 1 (happy path), 2 (missing
  metadata / scope / owner), 3 (insufficient treasury UTxOs), 5
  (JSON round-trip). Tests drive `resolveReorganize` + a small
  `Identity`-monad mock env, then `reorganizeToIntent`, then
  `encodeSomeTreasuryIntent` ∘ `decodeTreasuryIntent` for the
  round-trip assertion. No live node; no IO beyond the mock.
- `amaru-treasury-tx.cabal` — expose
  `Amaru.Treasury.Tx.ReorganizeWizardSpec` in the
  `test-suite unit-tests` stanza's `other-modules` list
  (alphabetical, matching existing convention).

**S1's RED:** the new spec file references types
(`ReorganizeResolverInput`, `ReorganizeResolverEnv`,
`ReorganizeEnv`, the new `ReorganizeError` variants) and functions
(`resolveReorganize`, `reorganizeToIntent`) that do not exist yet →
compile-time RED on `nix develop -c just unit`.

**S1's GREEN:** add the types + resolver + translator → spec
compiles and every scenario passes.

**Gate evidence for S1:**

- `nix develop --quiet -c just unit --match "ReorganizeWizard"`
  passes (the new spec plus the existing parser spec; the parser
  spec is unaffected because `ReorganizeTodoSliceC` is preserved
  in this slice).
- `nix develop --quiet -c just unit` passes (full suite — no
  regressions in sibling wizards).
- `./gate.sh` passes (full ci + commit-message gate).

**Commit subject:** `feat(tx): reorganize-wizard resolver + pure translator`
**Tasks closed by this commit:** T001..T010 (see `tasks.md`).

---

### S2 — wire `Cli/ReorganizeWizard.hs` live runner; remove `ReorganizeTodoSliceC` (RED → GREEN)

**Goal:** replace the `runReorganizeWizardEither` Slice-1 stub body
(currently `pure (Left ReorganizeTodoSliceC)` after pre-flight
passes) with the live runner pipeline. The pipeline runs the
existing pre-flight checks (network guard, `--out` parent-dir),
then requires `--node-socket`, then opens the N2C backend, then
builds the `ReorganizeResolverEnv` record-of-functions from the
backend, then calls `resolveReorganize` + `reorganizeToIntent`,
then encodes via `encodeSomeTreasuryIntent` and writes the bytes
to `--out`. Remove `ReorganizeTodoSliceC` from `ReorganizeError`;
add `ReorganizeMissingNodeSocket` as the typed variant the
parser-spec tests assert on. Update `exitCodeFor`.

The existing parser spec's two `ReorganizeTodoSliceC` assertions
(lines 295 + 320 of `Cli/ReorganizeWizardParserSpec.hs`) get
swapped for `ReorganizeMissingNodeSocket` assertions — the test
flow becomes "valid pre-flight, no `--node-socket` set → typed
missing-socket error" which is the correct shape after S2.

**Owned files (S2 only):**

- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` — replace
  `runReorganizeWizardEither` stub body; add a helper
  `runReorganizeWizardLive :: GlobalOpts -> ReorganizeWizardOpts
  -> ReorganizeResolverEnv IO -> IO (Either ReorganizeError ())`
  (the live pipeline that takes the resolver env as an argument,
  enabling future test injection); update `runReorganizeWizard`
  (the `IO ()` shim) to call the new pipeline; update
  `exitCodeFor` to drop `ReorganizeTodoSliceC` and add
  `ReorganizeMissingNodeSocket` at exit 2.
- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` — remove
  `ReorganizeTodoSliceC` variant; add
  `ReorganizeMissingNodeSocket` variant (or pin its placement
  — see [`research.md` §4](./research.md#4-typed-error-placement)).
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`
  — update the two `ReorganizeTodoSliceC` assertions (lines
  295, 320) to assert `ReorganizeMissingNodeSocket` instead.
  No other changes; the other 13 spec items keep their existing
  assertions verbatim.

**S2's RED:** removing `ReorganizeTodoSliceC` from
`ReorganizeError` causes the existing parser spec to stop
compiling (the two assertions reference a constructor that no
longer exists) → compile-time RED on `nix develop -c just unit`.

**S2's GREEN:** update the two assertions to
`ReorganizeMissingNodeSocket`; implement the live pipeline; spec
compiles and passes.

**Gate evidence for S2:**

- `nix develop --quiet -c just unit --match "ReorganizeWizard"`
  passes (parser spec + Tx spec from S1).
- `nix develop --quiet -c just unit` passes (no regressions).
- `nix develop --quiet -c just ci` passes (full all-up gate).
- `./gate.sh` passes.
- Acceptance scenarios from `spec.md` all hold (see "Acceptance
  scenario coverage" matrix below).

**Commit subject:** `feat(cli): wire reorganize-wizard live runner`
**Tasks closed by this commit:** T011..T020 (see `tasks.md`).

---

### S3 — drop gate.sh + mark ready (orchestrator-owned, chore-only)

**Goal:** drop `gate.sh` from the worktree and mark PR #198 ready
for review. Final commit on the branch; no behavior change.

**Owned files (S3 only):**

- `gate.sh` — removed via `git rm gate.sh`.

**S3 is orchestrator-owned** (`chore:` exempt from `Tasks:` trailer
requirement). Before commit: run `finalization_audit` from the
`gate-script` skill; confirm every task in `tasks.md` is `[X]`;
confirm `git diff --check` is clean; confirm full `nix develop -c
just ci` passes (the same ci `gate.sh` would have run).

**Commit subject:** `chore: drop gate.sh (ready for review)`

After commit:

- `git push`
- `gh pr ready 198`
- Append `COMPLETE` + `NOTE PR #198 marked ready for review` to
  STATUS.md.

---

## Acceptance scenario coverage matrix

| Spec scenario | Slice | Test/evidence |
|---|---|---|
| US1 Acc. 1 — runner produces a `SomeTreasuryIntent` JSON for a healthy DevNet | S1 (resolver+translator) | `ReorganizeWizardSpec` happy-path scenario via mock `ReorganizeResolverEnv` |
| US1 Acc. 2 — `tx-build --intent <out>` then succeeds | S1 (resolver+translator); live confirmation deferred to #87 | The JSON envelope round-trips through `decodeTreasuryIntent` (US5); live dispatcher confirmation is #87's smoke |
| US2 Acc. 1 — `--metadata <absent>` → typed `ReorganizeMetadataReadError` | S1 | `ReorganizeWizardSpec` mock env: `sreReadMetadata` returns `Left "no such file"` → `Left ReorganizeMetadataReadError` |
| US2 Acc. 2 — `--metadata` decode failure → typed error | S1 | `ReorganizeWizardSpec` mock env returns `Left <decode-msg>` |
| US2 Acc. 3 — `--scope <not-in-metadata>` → typed `ReorganizeScopeNotInMetadata` | S1 | `ReorganizeWizardSpec` mock env returns a metadata with `tmTreasuries = singleton CoreDevelopment _`; spec passes `--scope ops_and_use_cases` → `Left ReorganizeScopeNotInMetadata` |
| US3 Acc. 1 — chain returns 0 treasury UTxOs → `ReorganizeInsufficientTreasuryUtxos 0` | S1 | `ReorganizeWizardSpec` mock env returns `[]` for treasury-address query |
| US3 Acc. 2 — chain returns 1 treasury UTxO → `ReorganizeInsufficientTreasuryUtxos 1` | S1 | `ReorganizeWizardSpec` mock env returns single-row list |
| US3 Acc. 3 — chain returns ≥2 UTxOs → happy path | S1 | overlaps with US1 Acc. 1 |
| US4 Acc. 1 — `--network preprod` rejected before any work (already shipped by #186) | S2 (re-verified) | existing `Cli/ReorganizeWizardParserSpec` `us5NetworkGuardSpec` — unchanged; passes after S2 |
| US4 Acc. 2 — `--network mainnet` rejected | S2 | same |
| US4 Acc. 3 — `--network devnet` accepted; runner proceeds | S2 | the updated assertion at line 320: with `--network devnet` + valid `--out` + missing `--node-socket`, the runner surfaces `ReorganizeMissingNodeSocket` (proves the network guard accepted devnet) |
| US5 — `decodeTreasuryIntent ∘ encodeSomeTreasuryIntent === id` | S1 | `ReorganizeWizardSpec` round-trip scenario uses the bytes written by the translator |

## Risks + mitigations

- **R1 — Removing `ReorganizeTodoSliceC` cross-slice churn.** The
  variant is the spec sentinel for #186's stub. Removing it in S2
  causes the existing parser spec to stop compiling. Mitigation:
  S2's RED is precisely "the parser spec stops compiling"; the
  GREEN flips the two assertions to `ReorganizeMissingNodeSocket`.
  Bisect-safe (both deltas in the same commit).
- **R2 — `--node-socket` testability.** The sibling
  `runScriptAccount` aborts with a plain stderr message and
  `exitWith 3` when `--node-socket` is absent. That shape is not
  testable from a unit spec (the `exitWith` throws an
  `ExitException` that test harnesses can intercept only via
  `try @ExitCode`). Mitigation: introduce a typed
  `ReorganizeMissingNodeSocket` variant surfaced at the
  `runReorganizeWizardEither :: … -> IO (Either ReorganizeError ())`
  boundary, and the `IO ()` shim `runReorganizeWizard` is the only
  place that calls `exitWith`. Mirrors the existing #186
  `runReorganizeWizardEither` shape (typed error + thin shim);
  the spec drives the typed-error boundary.
- **R3 — Mocking `ReorganizeResolverEnv` in S1's spec.** Sibling
  spec `StakeRewardInitWizardSpec` builds a similar mock env via
  `Identity`-monad effects. The pattern is well-trodden;
  cross-check by reading
  `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs`
  before the S1 driver+navigator dispatch. Mitigation: the S1
  brief names this sibling spec as the canonical template; the
  data-model document specifies the exact `ReorganizeResolverEnv`
  field signatures so the mock shape is fixed before
  implementation.
- **R4 — `permissionsRewardAccount` derivation correctness.** Per
  verdict B1, the reward account is derived inside
  `reorganizeToIntent` from `smPermissions.srHash` + the resolved
  network magic. The derivation needs to use the same network
  encoding as the library-core build path; otherwise the encoded
  JSON would round-trip through `decodeTreasuryIntent` but
  produce a `parseRewardAccountBech32` that disagrees with the
  ledger expectation. Mitigation: reuse the existing
  `Amaru.Treasury.Registry.Derive` helper (`scriptHashToHex` and
  the bech32 reward-account helper if present) AND assert byte
  equality in S1's spec by constructing the expected
  `AccountAddress` via the library API. The contract
  [`contracts/permissions-reward-account-contract.md`](./contracts/permissions-reward-account-contract.md)
  pins the derivation.
- **R5 — Deterministic ordering of treasury UTxOs.** Per verdict
  D1, the resolver sorts by `(TxId, TxIx)` ascending. The library-
  core build path does not care; the deterministic property is
  needed only for fixture-stable test assertions. Mitigation:
  the resolver sorts; the spec asserts the sorted shape; the
  library codec round-trips a `NonEmpty TxIn` and the order is
  preserved on the JSON side. Documented in
  [`contracts/resolver-contract.md`](./contracts/resolver-contract.md).
- **R6 — Empty wallet vs operator-typed seed.** Per verdict C1,
  the operator-typed `--funding-seed-txin` is the fuel UTxO; the
  wallet-addr chain query result is informational. The spec
  surfaces `ReorganizeWalletShortfall` only when the chain query
  returns no UTxOs at all (the wallet is fully empty). This is
  the sibling pattern. Mitigation: documented in
  [`contracts/resolver-contract.md`](./contracts/resolver-contract.md);
  S1's spec includes one scenario for "empty wallet → shortfall".

## Proof strategy summary

Every behavior change has a paired RED/GREEN in **the same commit**:

- **S1 — RED:** spec file references resolver/translator types +
  functions that don't exist → compile-time fail. **GREEN:**
  implement the types + functions → spec compiles and all
  scenarios pass.
- **S2 — RED:** removing `ReorganizeTodoSliceC` causes the
  existing parser spec to stop compiling. **GREEN:** update the
  two parser-spec assertions to `ReorganizeMissingNodeSocket`;
  implement the live pipeline → spec compiles and passes.
- **S3 — chore-only:** no proof needed; the final `nix develop
  -c just ci` run is the proof.

The amend-once-on-acceptance rule (mark `tasks.md` checkboxes in
the same slice commit) applies — see the `gate-script` skill's
"Stamping a reviewed slice" section.

## Live-boundary diagnostic

> "What system boundary does this exercise that the unit suite cannot?"

**Answer**: the live N2C backend (chain tip + flat UTxO query by
address + protocol parameters). The unit suite covers the
resolver/translator boundary via a mock `ReorganizeResolverEnv`;
it does NOT prove that the live wiring against
`Cardano.Node.Client.Provider` correctly threads the same
record-of-functions into the resolver.

**Choice**: deferred to operator follow-up (#87). The DevNet smoke
ticket #87 already owns the live invocation; gating #87 on this
slice landing first is the workflow. The plan does not add a live
smoke to `gate.sh` because:

1. The N2C backend requires a running cardano-node socket which
   is not available in the CI environment.
2. The sibling stake-reward-init runner shipped under the same
   pattern: unit spec at the resolver boundary, live smoke
   deferred to a separate child ticket.
3. The risk of a regression at the live boundary (e.g., the
   `queryUpperBoundSlot` signature changes upstream) is low
   because `cardano-node-clients` is SRP-pinned; the typecheck
   catches signature drift at S1 build time.

**Operator follow-up**: #87 (DevNet smoke) is filed and depends
on this PR merging first. The smoke's verifiable artifact is a
recorded CLI invocation transcript + the resulting intent JSON
filed under `journal/2026/` per the sibling DevNet smoke
convention.

## Deliverables enumeration (peer-surface coverage)

For each deliverable in `spec.md` § Deliverables, the canonical
peer artifact is the most recent sibling runner shipping under
the same resolver+translator pattern,
`Amaru.Treasury.Cli.StakeRewardInitWizard` +
`Amaru.Treasury.Tx.StakeRewardInitWizard` (shipped under #159).
Surface discovery via the canonical command:

```text
$ git grep -l 'StakeRewardInitWizard\|stake-reward-init-wizard' \
    .github/ flake.nix nix/ docs/ README.md CHANGELOG.md 2>/dev/null
# (returns no .github/, flake.nix, nix/, or top-level docs/README
# hits — siblings live entirely in cabal stanzas + test-suite)
```

**Conclusion**: no release / packaging / docs surfaces beyond
cabal are involved in this slice. The asciinema cast + operator
README section + docs page live with #188.

| Deliverable | Peer artifact | Peer surfaces | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (extend with resolver+translator) | `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` | cabal `library` stanza | yes (S1) |
| `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (replace stub; live runner) | `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs` | cabal `library` stanza | yes (S2) |
| `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` (NEW) | `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs` | cabal `test-suite unit-tests` | yes (S1) |
| `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` (update two assertions) | n/a (in-place edit) | cabal `test-suite unit-tests` | yes (S2) |
| `amaru-treasury-tx.cabal` (expose new spec module) | cabal `test-suite unit-tests.other-modules` list | cabal | yes (S1) |
| `gate.sh` removed | — | (worktree-only) | yes (S3) |

## Phase-stop assets ready

- [x] `gate.sh` committed (`d7c5c89f`)
- [x] `spec.md` committed (`60a3b87f`)
- [ ] `plan.md` + `research.md` + `data-model.md` + `contracts/`
      + `quickstart.md` committed (this commit)
- [ ] Block on `Q-002-plan-ready` for plan-review verdict
- [ ] After verdict: `tasks.md` (`/speckit.tasks`) → analyzer pass
      → S1 dispatch → S2 dispatch → S3 finalization

## Complexity Tracking

> Empty — no Constitution-check violations.
