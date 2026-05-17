---

description: "Task list for #157 — flatten devnet supercommand & add init intent encodings"
---

# Tasks: Flatten Devnet Supercommand & Add Init Intent Encodings (#157)

**Branch**: `157-flatten-devnet-cli`
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md) | **Data model**: [data-model.md](./data-model.md) | **Contracts**: [contracts/](./contracts) | **Quickstart**: [quickstart.md](./quickstart.md)

## Format

`- [ ] T### [P?] [Story?] description (file paths)`

- `[P]`: parallelizable (different files, no dependency on incomplete tasks).
- `[Story]`: user-story label (`US1`, `US2`, `US3`, `US4`).
- Each implementation slice is **one bisect-safe commit** (RED + GREEN fold into the same commit per resolve-ticket).
- Each behavior-changing commit body MUST carry a `Tasks: T###[, T###]` trailer; the orchestrator amends this file to `[X] T### (commit: <short-sha>)` at slice review.

## Subagent dispatch rule

Each `Subagent slice` heading below is one subagent run. The brief named there is the entire contract — the subagent does **not** load `resolve-ticket`, `speckit-implement`, or any other process skill. The orchestrator reviews the diff, reruns `./gate.sh`, and amends this file with the SHA before dispatching the next slice.

---

## Phase 1: Setup

- [X] T000 (commit: a81e53b) chore: add `gate.sh` at repo root (`gate.sh`).

**Checkpoint:** gate is committed and runnable.

---

## Phase 2: Foundational

No foundational task. The dispatch infrastructure (`Amaru.Treasury.Build.runBuildExcept`, `SomeTreasuryIntent`, `tx-build --intent`) already exists and is extended in place.

---

## Phase 3: User Story 2 — Remove `devnet` Supercommand (Priority: P1)

**Story**: Operators inspecting `amaru-treasury-tx --help` see no `devnet` command and no `registry-init` / `stake-reward-init` / `governance-withdrawal-init` / `disburse-submit` subcommands at any nesting level.

**Independent test**: `amaru-treasury-tx --help` shows no `devnet`; `amaru-treasury-tx devnet registry-init …` is rejected as unrecognized; `just ci` is green.

**Done first** because the parser flatten removes a large block of code without depending on the new intent variants — keeps subsequent slices small.

### Subagent slice 1 — Parser retirement + runner relocation (one commit)

- [X] T001 (commit: 967ca96) [US2] RED: extend `test/unit/Amaru/Treasury/Cli/ParserSpec.hs` with cases asserting that `amaru-treasury-tx devnet …`, `amaru-treasury-tx devnet registry-init …`, `amaru-treasury-tx devnet stake-reward-init …`, `amaru-treasury-tx devnet governance-withdrawal-init …`, and `amaru-treasury-tx devnet disburse-submit …` (and the bare `registry-init` / `stake-reward-init` / `governance-withdrawal-init` / `disburse-submit`) are rejected as unrecognized subcommands; tightened help-text check (per-line regex `^\s+devnet(\s|$)` matches nothing). (`test/unit/Amaru/Treasury/Cli/ParserSpec.hs`)
- [X] T002 (commit: 967ca96) [US2] GREEN: in the same commit, perform the lock-step parser-retirement + runner-relocation:
  1. Create `lib/Amaru/Treasury/Devnet/Runner.hs` and move the four `runDevnet*` IO drivers + four `DevnetXxxOpts` records out of `Cli/Devnet.hs` verbatim (no behavior change; no `optparse-applicative` imports in the new module).
  2. Delete `lib/Amaru/Treasury/Cli/Devnet.hs` (parser bits drop with it).
  3. Drop the `"devnet"` subparser line, the `devnetCmdP` parser, the four `CmdDevnet*` constructors, and the four `Amaru.Treasury.Cli.Devnet` imports from `lib/Amaru/Treasury/Cli.hs`.
  4. Drop the four `runDevnet*` imports + dispatch cases in `app/amaru-treasury-tx/Main.hs`.
  5. Update `amaru-treasury-tx.cabal`: expose `Amaru.Treasury.Devnet.Runner`; remove `Amaru.Treasury.Cli.Devnet`.
  6. Retarget `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`'s import block (lines 219–228) from `Amaru.Treasury.Cli.Devnet (...)` to `Amaru.Treasury.Devnet.Runner (...)` — same symbol list, import line only, NO body changes.
  7. Delete `test/unit/Amaru/Treasury/Cli/DevnetSpec.hs`.

  (`lib/Amaru/Treasury/Cli.hs`, `lib/Amaru/Treasury/Cli/Devnet.hs`, `lib/Amaru/Treasury/Devnet/Runner.hs`, `app/amaru-treasury-tx/Main.hs`, `amaru-treasury-tx.cabal`, `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`, `test/unit/Amaru/Treasury/Cli/ParserSpec.hs`, `test/unit/Amaru/Treasury/Cli/DevnetSpec.hs`)
- [X] T003 (commit: 967ca96) [US2] Verify `./gate.sh` is green at HEAD; `git diff origin/main -- lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit,DisburseSubmit}.hs` is empty (those four library runners must stay bit-identical); `git diff origin/main -- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` shows ONLY the import-line retarget (no body diff). *Reviewer note: two forced consequences accepted as bisect-safe mechanical fallout — `test/unit/Amaru/Treasury/Cli/EnvelopeSpec.hs` `cmdTag` dropped the three `CmdDevnet*` arms (type-system forced), and `SmokeSpec.hs` import block was alphabetically reordered by fourmolu when `Cli.Devnet` became `Devnet.Runner` (sort-only, body untouched).*

**Fold rule**: T001 + T002 + T003 are one commit. T001 is RED before T002 lands; T003 is the GREEN verification.

**Subagent brief** (template — orchestrator fills SHAs / final wording at dispatch):

```text
Task: T001, T002, T003

Context:
- One commit, bisect-safe, vertical. No push.
- Commit subject: `refactor(cli): drop devnet supercommand (#157)`.
- Commit body MUST include `Tasks: T001, T002, T003`.

Owned files:
- lib/Amaru/Treasury/Cli.hs
- lib/Amaru/Treasury/Cli/Devnet.hs                  (delete)
- lib/Amaru/Treasury/Devnet/Runner.hs               (new — moves runDevnet* + DevnetXxxOpts out of Cli/Devnet.hs)
- app/amaru-treasury-tx/Main.hs
- amaru-treasury-tx.cabal
- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs    (IMPORT LINE ONLY: retarget Amaru.Treasury.Cli.Devnet -> Amaru.Treasury.Devnet.Runner; same symbol list; no body change)
- test/unit/Amaru/Treasury/Cli/ParserSpec.hs        (new)
- test/unit/Amaru/Treasury/Cli/DevnetSpec.hs        (delete)

Forbidden scope:
- specs/, gate.sh, README, docs/, PR/issue metadata
- lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit,DisburseSubmit}.hs
  (must remain bit-identical; they are relocated *in place*, not modified)
- Any change to SmokeSpec OTHER than the import-block retarget at lines 219-228 (same symbol list, no body change)
- Any other test/devnet/ file

Required orchestrator analysis already applied:
- Cli.hs:104-107 has `CmdDevnetRegistryInit | CmdDevnetStakeRewardInit | CmdDevnetGovernanceWithdrawalInit | CmdDevnetDisburseSubmit`.
- Cli.hs:167-169 binds "devnet" -> devnetCmdP.
- Cli.hs:285-321 defines devnetCmdP with the four children.
- app/Main.hs imports `Amaru.Treasury.Cli.Devnet (runDevnet*)`.
- Cli/Devnet.hs is a mixed parser/runner module: it carries the
  optparse-applicative parsers AND the four `runDevnet*` IO
  drivers + four `DevnetXxxOpts` records that SmokeSpec imports.
  After this slice the runners + opts records live in
  `Amaru.Treasury.Devnet.Runner`; Cli/Devnet.hs is deleted; the
  parser-only bits drop with it.
- SmokeSpec imports (lines 219-228):
    Amaru.Treasury.Cli.Devnet
      ( DevnetDisburseSubmitOpts (..)
      , DevnetGovernanceWithdrawalInitOpts (..)
      , DevnetRegistryInitOpts (..)
      , DevnetStakeRewardInitOpts (..)
      , runDevnetDisburseSubmit
      , runDevnetGovernanceWithdrawalInit
      , runDevnetRegistryInit
      , runDevnetStakeRewardInit
      )
  Retarget the module name only; same symbol list; no body diff in SmokeSpec.

RED proof (write first, observe failing):
- Add `test/unit/Amaru/Treasury/Cli/ParserSpec.hs` cases that exec
  `parseArgs ["devnet"]` and the four `devnet <sub>` variants and
  assert each returns an unrecognized-subcommand failure.
- Tighten the help-text check: assert that the help body does NOT
  contain a subcommand line beginning with `devnet` (regex
  `^[[:space:]]+devnet([[:space:]]|$)` against the rendered help).
  Do NOT assert the literal substring "devnet" is absent — flag
  values and metavars elsewhere may legitimately contain the word.
- Run: `nix develop --quiet -c just unit "ParserSpec"` — must fail on the current HEAD before edits.

GREEN proof:
- Run: `nix develop --quiet -c just unit "ParserSpec"` — passes.
- Run: `./gate.sh` — passes (covers the devnet test-suite via `just ci`).
- `git diff origin/main -- lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit,DisburseSubmit}.hs`
  is empty (four library runners bit-identical).
- `git diff origin/main -- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
  shows ONLY the import-line retarget — no body diff. Confirm with
  `git diff --stat` showing ~1-2 line changes.
- `grep -RnE 'Amaru\.Treasury\.Cli\.Devnet' app/ lib/ test/` returns
  nothing (no remaining importer of the deleted module).
- `grep -RnE 'Amaru\.Treasury\.Devnet\.(RegistryInit|StakeRewardInit|GovernanceWithdrawalInit|DisburseSubmit|Runner)' app/`
  returns nothing (no shipped executable still reaches the runners;
  FR-005 coverage — `Devnet.Runner` is library-only).

Report back:
- diff stat
- RED evidence (failing or pending run)
- GREEN evidence (passing run + ./gate.sh tail + the diff/grep checks)
- confirmation that the four library runners are bit-identical and SmokeSpec body is unchanged
```

**Checkpoint:** Parser flat; `Cli/Devnet.hs` gone; SmokeSpec still compiles; help text clean.

---

## Phase 4: User Story 1 — Build Each Init Tx Via `tx-build --intent` (Priority: P1)

**Story**: For any of the seven init sub-action intents, `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>` produces an unsigned tx CBOR hex byte-identical to the CBOR the corresponding sub-transaction in the library function builds for the same logical inputs.

**Independent test**: Seven golden equivalence tests (`runFromIntent ctx intent` ≡ `extractedCore ctx inputs`) and seven round-trip properties pass; `nix build .#checks.{unit,golden}` green; `just schema-check` green.

### Subagent slice 2 — Intent JSON scaffolding for the seven sub-actions (one commit)

- [X] T010 (commit: 485e995) [US1] RED: extend `test/unit/Amaru/Treasury/IntentJSONSpec.hs` with one round-trip property per new sub-action (`decode . encode ≡ Right` for each of: `registry-init-seed-split`, `registry-init-mint`, `registry-init-reference-scripts`, `stake-reward-init-script-account`, `stake-reward-init-plain-account`, `governance-withdrawal-init-proposal`, `governance-withdrawal-init-materialization`); extend `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs` with a presence check for each new variant in the rendered schema. (`test/unit/Amaru/Treasury/IntentJSONSpec.hs`, `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`)
- [X] T011 (commit: 485e995) [US1] GREEN: extend `Action`, `SAction`, `Payload`, `Translated` with the seven flat constructors per `data-model.md`; introduce seven `*Inputs` records with `FromJSON` / `ToJSON` (decoder accepts any `network: Text` — no policy guard, per the dispatcher-policy rule); add seven `SomeTreasuryIntent` arms. *Reviewer note: subagent shipped **option β** (empty placeholder records) across all three families; slices 3a/3b/3c will add real fields when extracting the construction cores. `Translated x = ()` placeholders too; `translateIntent` short-circuits `Left` before any consumer sees the `()`. `runBuildExcept` carries seven `BuildActionIntent`/`BuildPhaseUnsupported` stub arms to keep the case exhaustive — slices 3a/3b/3c replace.* (`lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/IntentJSON/Common.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`, `lib/Amaru/Treasury/Build.hs`)
- [X] T012 (commit: 485e995) [US1] Regenerate `docs/assets/intent-schema.json` (`just update-schema`); `just schema-check` green. *Reviewer note: subagent flagged that the schema's `network` enum is currently `["mainnet","preprod","preview"]` — `"devnet"` is not in the enum even though the seven new actions are intended to be DevNet-only. Decoder accepts `"devnet"` (no decoder guard, by design), but the JSON Schema would reject it on external validation. Slice 4 owns the dispatcher-level `requireDevnet` policy AND should grow the schema's `network` enum to include `"devnet"`.* (`docs/assets/intent-schema.json`, `app/amaru-treasury-intent-schema/Main.hs` if hand-rolled)

**Fold rule**: T010 + T011 + T012 are one commit.

**Subagent brief**:

```text
Task: T010, T011, T012

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(intent): add seven init sub-action variants (#157)`.
- Commit body MUST include `Tasks: T010, T011, T012`.

Owned files:
- lib/Amaru/Treasury/IntentJSON.hs
- lib/Amaru/Treasury/IntentJSON/Common.hs
- lib/Amaru/Treasury/IntentJSON/Schema.hs
- app/amaru-treasury-intent-schema/Main.hs (only if hand-rolled)
- docs/assets/intent-schema.json
- test/unit/Amaru/Treasury/IntentJSONSpec.hs
- test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs
- amaru-treasury-tx.cabal (if a new module is added)

Forbidden scope:
- specs/, gate.sh, README, docs/local-devnet-smoke.md, PR metadata
- lib/Amaru/Treasury/Build.hs (dispatch arms land in slices 3a/3b/3c)
- lib/Amaru/Treasury/Devnet/*.hs
- Any policy/guard on `network` (deliberately deferred to slice 4)

Required orchestrator analysis already applied:
- Current Action enum: Swap | Disburse | Withdraw | Reorganize.
- Type families Payload and Translated at IntentJSON.hs:171-185.
- SomeTreasuryIntent existential at IntentJSON.hs:505-509.
- Decoders accept any `network: Text` today (IntentJSON.hs:619, 484).

RED proof:
- IMPORTANT: round-trip properties for the new variants reference
  types that don't exist on `main`, so the test won't *fail* on
  unmodified HEAD — it won't *compile*. The RED moment in this
  slice is satisfied by either (a) committing a placeholder
  property `it "round-trip <variant>" pendingWith "T011 not landed"`
  first and observing pending, then replacing with the real
  property in the same commit, or (b) showing the type-error
  output from `cabal build` before the type extensions land.
  Document whichever path is taken in the RED evidence section of
  the report.

GREEN proof:
- `nix develop --quiet -c just unit "IntentJSON"` — passes.
- `nix develop --quiet -c just schema-check` — passes.
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence
- GREEN evidence (unit + schema-check + ./gate.sh)
- Confirmation: no `network` guard added to any decoder.
```

### Subagent slice 3a — Registry-init dispatch + 3 CBOR-equivalence goldens (one commit)

- [X] T020 (commit: 7e800d5) [US1] RED: add `test/golden/RegistryInitIntentSpec.hs` (flat — matches existing golden-suite convention `test/golden/*Spec.hs`, not the `Amaru/Treasury/` subpath the brief originally suggested) with three goldens that materialize a fixture intent + drive `runFromIntent` and assert byte-identical CBOR vs. the extracted construction core for `registry-init-seed-split`, `registry-init-mint`, `registry-init-reference-scripts`; commit fixtures (`test/fixtures/intent/registry-init-{seed-split,mint,reference-scripts}.json`); supply a single-source-of-truth fixture helper `test/golden/Support/RegistryInitFixtures.hs`. (`test/golden/RegistryInitIntentSpec.hs`, `test/golden/Support/RegistryInitFixtures.hs`, `test/fixtures/intent/…`)
- [X] T021 (commit: 7e800d5) [US1] GREEN: extracted per-sub-tx construction cores from `lib/Amaru/Treasury/Devnet/RegistryInit.hs` (seed-split, mint, reference-scripts) into pure functions reachable from a new `lib/Amaru/Treasury/Build/RegistryInit.hs`; dispatched three real arms in `runBuildExcept` (replacing the slice-2 `BuildActionIntent`/`BuildPhaseUnsupported` stubs); filled in `RegistryInit{SeedSplit,Mint,ReferenceScripts}Inputs` records (option α — fields derived from each submitter's signature); replaced `Translated 'RegistryInit*` `()` placeholders with real `RegistryInit{SeedSplit,Mint,ReferenceScripts}Tx` records; replaced `translateIntent` `Left "..."` arms with real translators. The existing submitter code paths in `RegistryInit.hs` stay on top of the extracted cores; public signatures preserved; SmokeSpec untouched. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/RegistryInit.hs`, `lib/Amaru/Treasury/Devnet/RegistryInit.hs`, `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`, `docs/assets/intent-schema.json`, `amaru-treasury-tx.cabal`)
- [X] T022 (commit: 7e800d5) [US1] Verified: `nix build .#checks.golden` and `./gate.sh` green; `SmokeSpec` compiles unchanged; library runner bit-identical to slice-1 except for the extraction-only deltas inside the three submitters. *Orchestrator-applied plumbing fixes (mechanical, folded into this slice's commit): (a) added `cardano-ledger-binary` to the golden-tests build-depends in `amaru-treasury-tx.cabal`; (b) constrained `keyHashAddr` in `RegistryInitFixtures.hs` to `KeyHash Payment` (GHC role check); (c) split `sampledSlot = 1_000_000` from `upperBoundSlot = 1_000_100` so the validity-interval Conway phase-1 check (`slot < invalidHereafter`) passes; (d) shrank the mint fixture's per-script ExUnits from `(200M mem, 800K steps) ×2` to `(2M mem, 500M steps) ×2` so the total stays under the mainnet 16.5M-mem / 10B-steps per-tx ceiling; (e) updated the slice-2 `IntentJSONSpec` round-trip generators to construct `RegistryInitMintInputs` and `RegistryInitReferenceScriptsInputs` with the new fields (slice 2 had shipped them empty under option β; this slice promotes them to option α).*

**Fold rule**: T020 + T021 + T022 are one commit. The extraction in T021 must preserve `RegistryInit.hs`'s existing semantic behavior; the golden in T020 holds that invariant byte-by-byte.

**Subagent brief**:

```text
Task: T020, T021, T022

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(build): dispatch registry-init sub-action intents (#157)`.
- Commit body MUST include `Tasks: T020, T021, T022`.

Owned files:
- lib/Amaru/Treasury/Build.hs
- lib/Amaru/Treasury/Devnet/RegistryInit.hs        (extraction only)
- test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs
- test/fixtures/intent/registry-init-seed-split.json
- test/fixtures/intent/registry-init-mint.json
- test/fixtures/intent/registry-init-reference-scripts.json
- amaru-treasury-tx.cabal (if a new test-suite component or module appears)

Forbidden scope:
- specs/, gate.sh, README, docs/, PR metadata
- lib/Amaru/Treasury/IntentJSON*.hs (frozen by slice 2)
- lib/Amaru/Treasury/Devnet/StakeRewardInit.hs (slice 3b)
- lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs (slice 3c)
- lib/Amaru/Treasury/Devnet/DisburseSubmit.hs
- Any `network` policy / requireDevnet guard (slice 4)
- The submitter functions in RegistryInit.hs (`submitSeedSplit`,
  `submitRegistryNfts`, `submitReferenceScripts`,
  `publishDevnetRegistryInit`) must keep their current public
  signatures and behavior; only their internal call to the
  construction core may move.

Required orchestrator analysis already applied:
- RegistryInit.hs:339 submitSeedSplit; :377 submitRegistryNfts;
  :448 submitReferenceScripts; :495 buildSubmitAndWait.
- The extraction targets are the pre-submit body construction blocks
  inside each `submitX` — extract to top-level pure builders
  consumed by both (a) the existing submitter and (b) the new
  Build.hs dispatch arms.
- SmokeSpec consumes `publishDevnetRegistryInit` (or its caller) —
  do not change its public surface.

RED proof:
- Goldens compare `brCborBytes (runFromIntent ctx intent)` against
  `brCborBytes (extractedCore ctx inputs)`. Both must be derived
  from the same logical inputs (test-support helper or shared
  fixture builder).
- IMPORTANT: the goldens reference dispatch arms that don't exist
  on `main`, so they won't compile until T021 lands. Same as
  slice 2 RED: either ship a `pendingWith "T021 not landed"`
  scaffold first and observe pending, then replace with the real
  goldens in the same commit, or capture the type-error output
  before T021 — pick one and report which.
- Run: `nix develop --quiet -c just golden "RegistryInitIntent"` —
  must fail (or pend) on HEAD before edits.

GREEN proof:
- `nix develop --quiet -c just golden "RegistryInitIntent"` — passes.
- `nix develop --quiet -c just unit` — passes (SmokeSpec unchanged).
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence (failing goldens)
- GREEN evidence (passing goldens + ./gate.sh)
- Explicit confirmation: `git diff origin/main -- lib/Amaru/Treasury/Devnet/RegistryInit.hs`
  shows extraction-only deltas; public submitter surface unchanged.
```

### Subagent slice 3b — Stake-reward-init dispatch + 2 CBOR-equivalence goldens (one commit)

- [X] T030 (commit: 34880a4) [US1] RED: `test/golden/StakeRewardInitIntentSpec.hs` (flat under `test/golden/`, matches slice 3a convention) with two goldens (`script-account`, `plain-account`); fixtures `test/fixtures/intent/stake-reward-init-{script-account,plain-account}.json`; fixture-helper `test/golden/Support/StakeRewardInitFixtures.hs`. (`test/golden/StakeRewardInitIntentSpec.hs`, `test/golden/Support/StakeRewardInitFixtures.hs`, `test/fixtures/intent/…`)
- [X] T031 (commit: 34880a4) [US1] GREEN: extracted construction cores from `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs` (script-account, plain-account) and exposed them via the new `lib/Amaru/Treasury/Build/StakeRewardInit.hs` module; replaced the two slice-2 `BuildActionIntent`/`BuildPhaseUnsupported` stubs in `Amaru.Treasury.Build.runBuildExcept` with real dispatch; filled in `StakeRewardInit{ScriptAccount,PlainAccount}Inputs` records (option α — fields from each register helper's signature); replaced `Translated 'StakeRewardInit* = ()` placeholders with real `StakeRewardInit{ScriptAccount,PlainAccount}Tx` records + matching `translateIntent` arms; regenerated `docs/assets/intent-schema.json` with the two real `stake-reward-init-*` `$defs`. Existing public surface preserved (`setupDevnetStakeRewards`, `submitStakeRewardSetup`, `registerScriptRewardAccount`, `registerPlainRewardAccount`, `stakeRewardSetupProgram`). SmokeSpec bit-identical. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/StakeRewardInit.hs`, `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`, `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`, `docs/assets/intent-schema.json`, `amaru-treasury-tx.cabal`)
- [X] T032 (commit: 34880a4) [US1] Verified: 460 unit examples pass, 5 goldens pass (3 registry-init + 2 stake-reward-init), `./gate.sh` green. *Orchestrator-applied plumbing fixes (mechanical, folded into this commit): (a) hlint asked for `StakeRewardInitPlainAccountInputs` to be a `newtype` (single-field single-constructor); applied; (b) updated the slice-2 `genStakeRewardInit*Intent` round-trip generators in `test/unit/Amaru/Treasury/IntentJSONSpec.hs` to construct the now-non-empty records (slice 2 had shipped them empty under option β). Subagent's RED-step approach: no `pendingWith` scaffold — the cores + dispatcher land in the same commit and the goldens act as the self-check (matches the as-merged shape of slice 3a's `RegistryInitIntentSpec`).*

**Fold rule**: T030 + T031 + T032 are one commit. As 3a.

**Subagent brief**: mirror 3a's structure (including the same RED-pending convention), swap `RegistryInit` for `StakeRewardInit`, two goldens not three, owned files as listed in T030/T031. Commit subject `feat(build): dispatch stake-reward-init sub-action intents (#157)`. Trailer `Tasks: T030, T031, T032`.

### Subagent slice 3c — Governance-withdrawal-init dispatch + 2 CBOR-equivalence goldens (one commit)

- [X] T040 (commit: df50fa7) [US1] RED: `test/golden/GovernanceWithdrawalInitIntentSpec.hs` (flat under `test/golden/`) with two goldens (`proposal`, `materialization`); fixtures `test/fixtures/intent/governance-withdrawal-init-{proposal,materialization}.json`; fixture-helper `test/golden/Support/GovernanceWithdrawalInitFixtures.hs`. (`test/golden/GovernanceWithdrawalInitIntentSpec.hs`, `test/golden/Support/GovernanceWithdrawalInitFixtures.hs`, `test/fixtures/intent/…`)
- [X] T041 (commit: df50fa7) [US1] GREEN: extracted two construction cores from `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs` into a new `Devnet/GovernanceWithdrawalInit/Core.hs` submodule so the dispatcher can pull them without re-introducing the `Build → Report → Build` module cycle the live runner carries. Proposal core wraps a parameter-driven variant of `governanceWithdrawalProposalProgram`; materialization core wraps the existing `withdrawProgram` from `Tx.Withdraw`. Two dispatch arms in `runBuildExcept` replace the slice-2 stubs. *The proposal arm skips `validateFinalPhase1` because the tx carries a treasury-withdrawal proposal whose return-account existence check requires reward-account state the offline ChainContext does not carry — same rationale as the existing `hasWithdrawals` skip in `Build/Common.hs`.* `GovernanceWithdrawalInit{Proposal,Materialization}Inputs` records filled (option α; 6 and 5 JSON fields); matching `Translated` types + `translateIntent` arms. Schema regenerated. Public submitter surface preserved. SmokeSpec bit-identical. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`, `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`, `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`, `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`, `docs/assets/intent-schema.json`, `amaru-treasury-tx.cabal`)
- [X] T042 (commit: df50fa7) [US1] Verified: 460 unit examples pass, 7 goldens pass (3 registry-init + 2 stake-reward-init + 2 governance-withdrawal-init), `./gate.sh` green. *Residual risks flagged by subagent (acceptable; not blocking): (1) the proposal arm uses a `materializeResultSkipPhase1` helper to bypass `TreasuryWithdrawalReturnAccountsDoNotExist` — a future refactor could fold the skip into `validateFinalPhase1` cross-cuttingly; (2) the proposal JSON payload carries a single `voterKeyHash` reinterpreted as voter staking + voter payment + DRep — matches the production submitter's single-DSIGN derivation; payload-shape extension is bisect-safe (additive) if multi-key voters ever land.*

**Fold rule**: T040 + T041 + T042 are one commit. As 3a.

**Subagent brief**: mirror 3a's structure (including the same RED-pending convention), swap `RegistryInit` for `GovernanceWithdrawalInit`. Commit subject `feat(build): dispatch governance-withdrawal-init sub-action intents (#157)`. Trailer `Tasks: T040, T041, T042`.

**Checkpoint:** All seven sub-action intents build byte-identical CBOR through `tx-build`. US1 is independently testable end-to-end on a live socket.

---

## Phase 5: User Story 3 — `SmokeSpec` Survives Via Library Functions (Priority: P1)

**Story**: `Amaru.Treasury.Devnet.SmokeSpec` keeps compiling and passing while calling the relocated runners directly as library functions, no CLI shelling.

**Independent test**: `nix build .#checks.devnet-smoke` (or equivalent) passes; grep shows zero `amaru-treasury-tx devnet …` invocations in `test/devnet/`.

US3 has **no dedicated slice** — it is preserved as a side-effect invariant of slices 1, 3a, 3b, 3c. The verification task below confirms it.

### Verification task (orchestrator-owned, no subagent)

- [ ] T050 [US3] After slice 3c lands, verify SmokeSpec library-only consumption by running ALL of: (a) `grep -RnE 'amaru-treasury-tx[ ]+devnet' test/` returns zero matches (no CLI shelling), (b) `grep -RnE 'Amaru\.Treasury\.Cli\.Devnet' test/` returns zero matches (no import of the deleted CLI glue module), (c) `nix develop --quiet -c just unit` passes (SmokeSpec compiles), and (d) the live `just devnet-smoke` phases that exist for the four runners pass; record the verification output in the slice-3c review note (no new commit needed unless a regression appears).

**Checkpoint:** SmokeSpec proven unchanged in behavior; library proof survives.

---

## Phase 6: Cross-Cutting — Network Policy In The Dispatcher

Not a user story; covers the parent #156 invariant *"every CLI bootstrap path refuses non-DevNet networks (fail-closed)"*.

### Subagent slice 4 — `requireDevnet` helper + regression suite (one commit)

- [X] T060 (commit: 3430603) RED: added `test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs` with 7 cases — for each init sub-action, build a fixture intent with `network: mainnet` (constructed inline from the slice-3a/3b/3c Support helpers via a `tiNetwork` swap so the Support modules stay frozen) and assert `runFromIntentEither` returns `Left BuildError{…}` against a **bottom `ChainContext`** (`error "NetworkGuardSpec: ChainContext was forced before requireDevnet had a chance to reject the intent — the dispatcher network guard regressed."`). The bottom is the proof of short-circuit: if the guard regresses, the bottom gets forced and the test fails loudly. Subagent demonstrated this by temporarily commenting `requireDevnet` in one arm and observing exactly that failure. ALSO: extended the schema's `network` enum to include `"devnet"` (flagged at slice-2 review — applied across ALL 11 action enums in `docs/assets/intent-schema.json`, not just the 7 init ones; consistent and one-line per action). (`test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`, `docs/assets/intent-schema.json`)
- [X] T061 (commit: 3430603) GREEN: introduced `requireDevnet :: Text -> ExceptT BuildError IO ()` in `Amaru.Treasury.Build` and called it as the FIRST action in each of the 7 init dispatch arms in `runBuildExcept`. `BuildError` shape decision: reused `BuildActionIntent` + `BuildPhaseUnsupported` (no new BuildAction / BuildFailurePhase constructors) and added a new `DiagnosticUnsupportedNetwork :: Text -> BuildDiagnostic` constructor — clearer signal than overloading `DiagnosticUnsupportedAction`; renderer maps it to `"unsupported-network"` code + operator-friendly prose. Decoder unchanged (no asymmetric guard vs swap/disburse/withdraw). (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/Error/Types.hs`, `lib/Amaru/Treasury/Build/Error/Render.hs`)
- [X] T062 (commit: 3430603) Verified: 467 unit examples pass (7 NetworkGuardSpec + the existing 460), 32 goldens pass + 1 pending (pre-existing usdm-disburse placeholder), `just schema-check` clean, `./gate.sh` green. *Subagent flagged a brief contradiction: slices 3a/3b/3c had shipped fixtures with `"network": "preprod"`, which the new `requireDevnet` guard rejects. The minimal in-scope fix — flip the `fixtureNetworkText` constant in 3 Support helpers + regenerate the 7 fixture JSONs to carry `"network": "devnet"` (10 lines total) — is necessary, not optional; without it the 7 happy-path goldens would have regressed. Production Devnet runners (which emit `"network": "devnet"`) and SmokeSpec are bit-identical; slice-3a/3b/3c per-family Build modules are bit-identical; decoder is bit-identical.*

**Fold rule**: T060 + T061 + T062 are one commit.

**Subagent brief**:

```text
Task: T060, T061, T062

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(build): reject non-devnet networks for init intents (#157)`.
- Commit body MUST include `Tasks: T060, T061, T062`.

Owned files:
- lib/Amaru/Treasury/Build.hs
- test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs
- test/fixtures/intent/*-mainnet.json (if a separate fixture is preferred)
- amaru-treasury-tx.cabal (if a new test module appears)

Forbidden scope:
- lib/Amaru/Treasury/IntentJSON*.hs — the decoder MUST NOT enforce
  this policy (asymmetry vs. swap/disburse/withdraw decoders).
  See specs/157-flatten-devnet-cli/research.md "Network safety in
  the Build.hs dispatcher arm".
- lib/Amaru/Treasury/Devnet/*.hs (no change)
- specs/, gate.sh, docs/, PR metadata

Required orchestrator analysis already applied:
- Existing dispatch shape: runBuildExcept at lib/Amaru/Treasury/Build.hs:96
  cases by SAction. Add the call to requireDevnet before each init arm.
- BuildError types live alongside; the guard surfaces a typed error.
  Pick a constructor that nests under `BuildActionXxx` for each
  init arm or introduce a new `BuildPhaseNetwork` phase tag — note
  which choice in the report.
- "Dummy ChainContext that fails loudly if touched": the simplest
  construction is `error "ChainContext touched before requireDevnet"`
  per record field, OR a Show-only stub if `ChainContext` is
  abstract. Inspect `Amaru.Treasury.Build` to confirm the
  constructor visibility before writing the test; if construction
  is non-trivial, prefer `runExceptT (requireDevnet "mainnet")`
  unit-tested directly and a smaller end-to-end probe.

RED proof:
- The seven mainnet-intent test cases run runFromIntentEither against
  the dummy/probe context — must fail (no guard yet) before T061
  lands. Same RED-pending caveat as slices 2/3a/3b/3c applies if
  the test file references symbols not yet present.
- Run: `nix develop --quiet -c just unit "NetworkGuardSpec"` — must fail.

GREEN proof:
- `nix develop --quiet -c just unit "NetworkGuardSpec"` — passes.
- `nix develop --quiet -c just golden` — the seven equivalence goldens
  from slices 3a/3b/3c still pass (no regression).
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence
- GREEN evidence
- Confirmation: no edits to lib/Amaru/Treasury/IntentJSON*.hs.
```

**Checkpoint:** Mainnet/preprod fails closed at the dispatcher before any effect; decoders remain symmetric across all intent variants.

---

## Phase 7: User Story 4 — Docs Reflect The New Operator Path (Priority: P2)

**Story**: `README.md`, `docs/local-devnet-smoke.md`, and PR body describe `tx-build --intent <bootstrap-intent.json>` as the operator path; old `devnet <action>` references are gone; wizards (#158–#160) and bash smoke (#161) are forward-referenced.

**Independent test**: `grep -RnE 'devnet[ ]+(registry-init|stake-reward-init|governance-withdrawal-init|disburse-submit)' README.md docs/` returns zero matches; the new operator path is documented end-to-end.

### Orchestrator slice 5 — Documentation alignment (one commit, orchestrator-owned)

- [ ] T070 [US4] Update `README.md`: replace any `amaru-treasury-tx devnet …` invocation with the `tx-build --intent <bootstrap-intent.json>` operator path; add a short forward reference to #158–#160 (wizards) and #161 (bash smoke). (`README.md`)
- [ ] T071 [US4] Update `docs/local-devnet-smoke.md`: bootstrap section describes the intent → `tx-build` operator path; identify `SmokeSpec` as library proof and note `smoke.sh` arrives in #161; remove stale `devnet <action>` references. (`docs/local-devnet-smoke.md`)
- [ ] T072 [US4] Update PR #162 body to mark the docs phase ready and refresh the status block.

**Fold rule**: T070 + T071 are one commit (`docs(157): update operator path for intent-driven bootstrap`). T072 is a `gh pr edit` action, not a commit.

**Checkpoint:** Docs and metadata agree with delivered behavior; PR can be reviewed.

---

## Phase 8: Polish & Ready

### Orchestrator slice 6 — Drop `gate.sh` & mark ready (one commit + one `gh` action)

- [ ] T080 chore: `git rm gate.sh` and commit (`chore: drop gate.sh (ready for review) (#157)`). (`gate.sh`)
- [ ] T081 `gh pr ready 162`; do not self-approve. Do NOT edit the PR body here — the docs-phase body refresh in T072 is the last body edit before merge.

**Checkpoint:** `gate.sh` absent from HEAD; PR is ready for external review; orchestrator does NOT merge.

---

## Dependencies

```text
T000 (done)
  → Slice 1 [US2]         (T001-T003)
  → Slice 2 [US1]         (T010-T012)
       → Slice 3a [US1]   (T020-T022)
       → Slice 3b [US1]   (T030-T032)   } 3a/3b/3c can be parallel after slice 2
       → Slice 3c [US1]   (T040-T042)   } if the user authorizes parallel subagents
            → Slice 4 (T060-T062)        (requires the seven init arms to exist)
                 → T050 [US3]            (verification only)
                 → Slice 5 [US4] (T070-T072)
                      → Slice 6 (T080-T081)
```

Slice 1 (parser) and Slice 2 (intent JSON) can also run in parallel if you authorize — they touch disjoint files (`Cli*.hs` vs. `IntentJSON*.hs`). Default to sequential per resolve-ticket "one subagent at a time unless explicitly allowed".

## Parallel execution opportunities

- After slice 2 lands, slices 3a / 3b / 3c are independent at the file level (different `Devnet/*Init.hs` modules, different golden specs, different fixture files; shared edits to `Build.hs` would conflict — orchestrator must serialize the `Build.hs` arms across the three slices, OR pre-stage the three arms as empty `case` branches in slice 2's extension to remove the conflict).
- Slice 1 and Slice 2 touch disjoint trees and can be parallel under explicit user approval.
- Slices 4, 5, 6 are strictly sequential.

## Implementation strategy

- **MVP increment**: Slice 1 (parser flat) + Slice 2 (intent JSON scaffold). At this point the CLI no longer exposes `devnet …`, the seven intent variants round-trip, and the schema is up to date — but `tx-build` cannot yet *build* any of them. This is a reviewable "API shape" milestone.
- **Functional increment**: + Slice 3a/3b/3c (all seven dispatch arms with CBOR-equivalence proof). At this point a fixture intent yields the same CBOR the library would, byte-for-byte.
- **Safety increment**: + Slice 4 (`requireDevnet`). Mainnet/preprod fail closed.
- **Ship increment**: + Slice 5 (docs) + Slice 6 (drop gate, ready).

## Format validation

- Every task above starts with `- [ ]` (or `- [X]` for T000), has a `T###` id, a `[Story]` label where applicable, and a file path.
- Behavior-changing slice commits MUST carry `Tasks: T###[, T###]` trailers; the orchestrator amends `[X] T### (commit: <sha>)` at slice review (resolve-ticket two-sided link).
