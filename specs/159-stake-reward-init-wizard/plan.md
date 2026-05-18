# Implementation Plan: stake-reward-init-wizard

**Branch**: `159-stake-reward-init-wizard` | **Date**: 2026-05-18 | **Spec**: [spec.md](./spec.md)
**Issue**: [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessors**:
- [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162) (shipped the two `StakeRewardInit*` intent variants this wizard targets, plus the `requireDevnet` guard in the `tx-build` dispatcher)
- [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158) — merged via PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165) (architectural and stylistic template for this PR)
**Parked Follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — resumable client state; promotes this stupid baseline to a real wizard

## Status

**Current**: Branch + draft PR ([#168](https://github.com/lambdasistemi/amaru-treasury-tx/pull/168)) + `gate.sh` in place. `spec.md` and requirements checklist committed and reviewed. This plan is the contract subagents read before slice dispatch.

**Blockers**: None. #157 already shipped the two `SomeTreasuryIntent` variants (`StakeRewardInitScriptAccount`, `StakeRewardInitPlainAccount`), the matching `Translated`/`Inputs` records, the `requireDevnet` guard in the `tx-build` dispatcher, and the `Support.StakeRewardInitFixtures` single-source-of-truth helper this wizard's parity goldens derive from. #158 shipped the architectural template (`Amaru.Treasury.Tx.RegistryInitWizard` / `Amaru.Treasury.Cli.RegistryInitWizard`) and the parser/golden/network-guard/no-simulation patterns.

## Implementation Ownership

The orchestrator owns this specification, plan, task breakdown, `gate.sh`, contracts, quickstart, local review, final PR metadata, and docs alignment. Behavior-changing code slices are implemented by one subagent at a time after this plan and `tasks.md` have passed local review.

Each subagent receives a narrow brief naming exact task ids, owned files / modules, forbidden scope, RED proof, GREEN proof, and the gate to run. The orchestrator reviews the returned diff, reruns `./gate.sh` locally, updates `tasks.md` (`[X] T### (commit: <sha>)`) plus PR metadata, and only then starts the next subagent. WIP.md tailing during the run catches scope creep / RED-skipping early.

## Parent Carry-Forward Invariants (from #156)

- Shipped CLI bootstrap surface produces unsigned txs only.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/StakeRewardInit.hs` and the cores it pulls from `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface.
- Library proof (`SmokeSpec`) survives every child; CLI proof (`smoke.sh`) lands in #161.
- Network safety: every CLI bootstrap entry fails closed for non-DevNet networks.

## Deliberate override: wizard-vs-stupid-command

The parent #156 invariant *"a wizard only asks the operator for human decisions"* is **explicitly overridden** for #159, mirroring #158's override. Operator-typed inter-tx state (the registry artifact path + a funding-seed TxIn per invocation) is the design, by deliberate choice. The principle remains the design goal for [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163), which promotes the stupid baseline to a resumable wizard. Memory `feedback_wizard_vs_stupid_command` documents the rule; this plan documents the override.

## Summary

Add `Amaru.Treasury.Tx.StakeRewardInitWizard` (typed answers + pure translation per sub-action) and `Amaru.Treasury.Cli.StakeRewardInitWizard` (optparse-applicative parser with two subcommands + IO runner per sub-action), wired into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Each subcommand parses its operator flags, parses the supplied `--registry` file via the existing `readDevnetStakeRewardRegistry`, performs standard resolver work (network probe, wallet UTxO query, upper-bound-slot sampling — same shape as `RegistryInitWizard`), runs a pure translation that maps `Answers + Env → SomeTreasuryIntent`, and writes one bare `SomeTreasuryIntent` JSON to `--out`. No cross-step simulation; no registry chain re-verification (research D8); inter-tx values come from `--registry` + `--funding-seed-txin`. Two golden CBOR equivalence proofs (one per sub-action) hold the wizard-produced intent → `tx-build` byte-equal to the library core's output on the same logical inputs.

**FR-001 (subcommand emits one intent JSON) is satisfied incrementally across Slices 1–3.** Slice 1 ships parser scaffolding and a TODO-stub runner for both subcommands (gate green, `--help` works, runtime path exits non-zero). Slice 2 makes `script-account` functional. Slice 3 makes `plain-account` functional. Operators cannot use the wizard until Slice 3 lands; this is the deliberate cost of vertical bisect-safe slicing. The PR ships all slices together.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients` (Provider/Submitter), `cardano-tx-tools`, `cardano-ledger-conway`, `aeson` (intent JSON shape from #157), `optparse-applicative` (parser).
**Storage**: filesystem only — operator types flags + a registry artifact path, wizard writes one intent JSON per invocation.
**Testing**: Hspec unit + golden suites; round-trip property checks reusing the harness from #157's `StakeRewardInitIntentSpec`; `just schema-check` (unchanged — no schema delta).
**Target Platform**: Local Linux Nix development shell.
**Project Type**: Haskell CLI/library.
**Performance Goals**: No change in CLI parser construction cost or `tx-build` build time relative to existing wizards.
**Constraints**: Bisect-safe per commit; `./gate.sh` green at every HEAD; mainnet/preprod/preview fail-closed at the wizard resolver layer; no chain re-verification of the registry artifact (D8); **no internal cross-step simulation** (NFR-006); wizard source must contain zero references to `buildStakeRewardScriptAccountCore` / `buildStakeRewardPlainAccountCore`; no enforced ordering between subcommands (NFR-007).
**Scale/Scope**: Two subcommands, two pure translation functions, two goldens, two round-trip properties, parser test, network-safety test, docs alignment.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The wizard's emitted intents produce, through `tx-build`, the same CBOR the library cores produce; on-chain behavior is unchanged. The bash recipes do not include stake-reward-init as a separate concept (it was added in the Haskell stack); the constitution's "tie-break" rule is therefore inapplicable to this PR.

**II. Pure builders, impure shell**: PASS. The wizard's pure translation per sub-action returns `Either StakeRewardInitError SomeTreasuryIntent` and does no IO. The resolver layer's IO (chain queries + registry file read) is identical in shape to `RegistryInitWizard`'s resolver.

**III. Pluggable data source, local-node default**: PASS. The resolver uses the same `Provider`-based query helpers `RegistryInitWizard` uses; backend swap is at the existing seam, not in the wizard. The registry-file read is a `IO (Either String DevnetStakeRewardRegistry)` via the existing `readDevnetStakeRewardRegistry` — no new IO seam introduced.

**IV. Build, never sign or submit**: PASS. The wizard emits `SomeTreasuryIntent` JSON. Signing and submission stay on `witness` / `attach-witness` / `submit`. The wizard does NOT call `tx-build` internally (NFR-005).

**V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)**: PASS. Two goldens (one per sub-action) prove byte-for-byte CBOR equivalence between the wizard-produced intent → `tx-build` and the library core's output. RED + GREEN are paired in one reviewed commit per slice.

**VI. Hackage-ready Haskell**: PASS. Explicit exports, Haddock, fourmolu, hlint, `cabal check`, `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata body-shape change. The wizard does not emit Label-1694 metadata (stake-reward-init transactions are operational, not governance); the existing rationale flag set is not applicable to this subcommand family.

## Live-Boundary Diagnostic

Per the resolve-ticket diagnostic *"what system boundary does this exercise that the unit suite cannot?"*:

- The behavior changes are: a new CLI parser with two subcommands, a resolver that queries the chain for the network/wallet/slot (same shape as `RegistryInitWizard`'s resolver — already exercised by unit + golden coverage), a registry-file parse (using the existing `readDevnetStakeRewardRegistry`), and a pure translation per sub-action.
- The byte-identical CBOR equivalence proof (two goldens) is the parity gate. It holds "library-built CBOR" and "wizard-built-via-intent-and-tx-build CBOR" fixed against each other for every sub-action.
- The **live operator path** through the new subcommands is proved by the bash `smoke.sh` in #161. Deferring it here is explicit and matches the parent's two-proof-layer plan.
- The library proof at the live boundary continues to be `SmokeSpec` against `withDevnet`, which this PR preserves unchanged.
- The registry-file read is a deterministic file IO + JSON parse; no new chain boundary is introduced. The network probe at the resolver layer (D9) hits the same chain seam `RegistryInitWizard` already exercises.

Plan-review conclusion: no extra live-boundary smoke is required in `gate.sh` for #159. If a slice introduces a new live fetch outside what `RegistryInitWizard`'s resolver does, the slice's subagent brief must add a live-boundary check before the slice is reviewable.

## Vertical Review Slices

Each slice is one bisect-safe commit, dispatched as one subagent run, with RED + GREEN in the same commit. Slice numbers map to task ranges in `tasks.md`.

1. **Slice 1 — Wizard library scaffolding + CLI parser + parser test (RED + GREEN, one commit).** Create `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` with the two `Answers` records (`StakeRewardInitScriptAccountAnswers`, `StakeRewardInitPlainAccountAnswers`) and `StakeRewardInitError`. Create `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs` with `stakeRewardInitWizardOptsP` exposing two subcommands and the runner stub. Wire into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Update `amaru-treasury-tx.cabal` to expose the new modules. RED: parser test asserting (a) `amaru-treasury-tx stake-reward-init-wizard {script-account | plain-account}` parse correctly, (b) `--help` outputs list the required flags (`--wallet-addr`, `--registry`, `--funding-seed-txin`, `--out`, optional `--validity-hours`, `--log`, `--force`), (c) malformed `--funding-seed-txin` (not `<txid64hex>#<word16>`) is rejected at the parser, (d) missing required `--registry` flag is rejected at the parser, (e) `--out` pointing at a path whose parent directory does not exist surfaces a typed error before any work happens, (f) `--out` pointing at an existing file without `--force` surfaces a typed conflict error. GREEN: parser test passes; `just ci` and `./gate.sh` green. No translation logic yet; the runner stub prints a TODO error and exits non-zero. TxIn parser uses `Amaru.Treasury.LedgerParse.txInFromText`.

   Owned files:
   `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` (new — Answers + StakeRewardInitError),
   `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs` (new — parser + runner stub),
   `lib/Amaru/Treasury/Cli.hs` (wire subcommand),
   `app/amaru-treasury-tx/Main.hs` (wire runner),
   `amaru-treasury-tx.cabal` (expose new modules),
   `test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs` (new).

2. **Slice 2 — Resolver + script-account pure translation + golden + devnet network guard + registry parse (RED + GREEN, one commit).** Add `StakeRewardInitEnv` and the resolver for `script-account`: network probe, wallet UTxO query, upper-bound-slot sampling, and **registry-file parse via the existing `Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry`** (which already enforces `phase == "registry-init"` and `network == "devnet"` at the file-content level). **Mandatory: add the devnet-only chain-probe guard at the resolver layer** (FR-008 / spec User Story 3, research D9). The guard typed-fails with `StakeRewardInitNonDevnetNetwork` before any further chain query happens; covered by a unit test that drives the resolver against a `mainnet` / `preprod` / `preview` chain reply and asserts the typed error. **Critically: the wizard does NOT re-verify the parsed registry against chain state (research D8) — it trusts the operator's `--registry` commitment after the readDevnetStakeRewardRegistry parse gate.** Implement `stakeRewardInitScriptAccountToIntent :: StakeRewardInitEnv -> StakeRewardInitScriptAccountAnswers -> Either StakeRewardInitError SomeTreasuryIntent` (pure). The pure translation must (a) extract `dsrrTreasuryRef` → `treasuryRefTxIn` and `dsrrTreasuryScriptHash` → `treasuryScriptHash` for the payload, (b) build the wallet block with `wjTxIn = txInText (sasaFundingSeedTxIn answers)` (operator-typed override, mirroring `RegistryInitWizard.hs:623`) and `wjAddress = wsAddress (reWalletSelection env)`. Wire the runner's `script-account` arm to: resolve env → pure translation → `encodeSomeTreasuryIntent` → write to `--out`. Add `test/golden/Support/StakeRewardInitWizardFixtures.hs` that **derives wizard `Answers + Env` from the same underlying material `Support.StakeRewardInitFixtures` (#157) already uses for library-core goldens**, so the two sides cannot drift. RED: (a) golden test asserting that the wizard's intent → `tx-build` produces CBOR bytes identical to `buildStakeRewardScriptAccountCore`'s output on equivalent inputs; (b) unit test asserting the devnet network guard fires a typed error before any chain query on mainnet / preprod / preview; (c) unit test asserting a missing `--registry` file, an unparseable file, a file with `phase != "registry-init"`, and a file with `network != "devnet"` each surface a typed `StakeRewardInitRegistryReadError` (or equivalently shaped error variant) from the resolver; (d) unit test asserting the wallet-shortfall case surfaces `StakeRewardInitWalletShortfall` from the resolver (not from `tx-build`); the resolver layer's "shortfall" detection is the same shape as `RegistryInitWizard`'s — empty pure-ADA UTxOs set, not balance simulation. GREEN: goldens + unit tests + round-trip property for the `script-account` JSON pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` (add resolver + script-account translation + devnet network guard + registry-parse error variants),
   `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs` (wire script-account runner),
   `test/golden/Support/StakeRewardInitWizardFixtures.hs` (new — wizard fixtures derived from `Support.StakeRewardInitFixtures`),
   `test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardScriptAccountSpec.hs` (new),
   `test/fixtures/stake-reward-init-wizard/script-account-answers.json` (new),
   `test/fixtures/stake-reward-init-wizard/script-account-intent.json` (new golden output),
   `test/fixtures/stake-reward-init-wizard/registry.json` (new — shared between both sub-actions; matches what a successful `registry-init-wizard reference-scripts` submission would produce, materialized from `Support.RegistryInitFixtures`'s reference-scripts fixture if practical),
   `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs` (new — round-trip for script-account; registry-parse error cases; wallet-shortfall),
   `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs` (new — devnet guard for both subcommands; plain-account case is scaffolded with placeholder Answers in Slice 2, refined in Slice 3).

3. **Slice 3 — Plain-account pure translation + golden (RED + GREEN, one commit).** Implement `stakeRewardInitPlainAccountToIntent :: StakeRewardInitEnv -> StakeRewardInitPlainAccountAnswers -> Either StakeRewardInitError SomeTreasuryIntent` (pure). The plain-account answers carry the operator-typed `--registry` path and `--funding-seed-txin`. Extract `dsrrPermissionsScriptHash` → `permissionsScriptHash` for the payload; build the wallet block with the operator-typed funding-seed TxIn (same override pattern as script-account). Wire the `plain-account` arm. RED: golden equivalence test for `buildStakeRewardPlainAccountCore`; round-trip property for the `plain-account` JSON; extend `StakeRewardInitWizardNetworkGuardSpec` to cover the plain-account arm. GREEN: golden + round-trip + network-guard pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` (add plain-account translation),
   `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs` (wire plain-account runner),
   `test/golden/Support/StakeRewardInitWizardFixtures.hs` (extend with plain-account fixture derivation),
   `test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardPlainAccountSpec.hs` (new),
   `test/fixtures/stake-reward-init-wizard/plain-account-answers.json` (new),
   `test/fixtures/stake-reward-init-wizard/plain-account-intent.json` (new),
   `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs` (extend with plain-account round-trip),
   `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs` (refine plain-account arm).

4. **Slice 4 — No-simulation grep enforcement (RED + GREEN, one commit).** Add a unit test that reads the wizard module sources (`lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` and `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`) via `Data.Text.IO.readFile` and asserts zero occurrences of `buildStakeRewardScriptAccountCore` and `buildStakeRewardPlainAccountCore` (NFR-006 / SC-007). **Unit test only** — no parallel `gate.sh` grep step (`./gate.sh` runs the suite). Modelled on #158's `RegistryInitWizardNoSimulationSpec` — strips Haskell comments before grep so a Haddock mention of the core names does not falsely fail the test. Slice 4 is intentionally narrow — one grep test, one commit. RED: the test runs and fails the moment any wizard module mentions a `*Core` symbol. GREEN: the wizard modules don't mention any, so the test passes; `./gate.sh` green.

   Owned files:
   `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNoSimulationSpec.hs` (new — grep enforcement, unit test only).

5. **Slice 5 — Documentation alignment (orchestrator-owned, single commit).** Update `README.md` and `docs/local-devnet-smoke.md` to describe `amaru-treasury-tx stake-reward-init-wizard {script-account | plain-account}` as the operator entry, show the two invocations consuming `--registry registry.json` + operator-typed `--funding-seed-txin`, carry the explicit "unsafe inter-step carry" warning (stale funding TxIn, wrong `--registry` path, registry from an unsubmitted bootstrap), and forward-reference #161 (bash smoke) and #163 (resumable client state). Refresh the PR body to match.

   Owned files:
   `README.md`,
   `docs/local-devnet-smoke.md`,
   `specs/159-stake-reward-init-wizard/tasks.md` (tick remaining `[ ]` items if any).

6. **Slice 6 — Drop `gate.sh` & ready (orchestrator-owned).**
   `chore: drop gate.sh (ready for review)`; `gh pr ready`.

## Project Structure

```text
specs/159-stake-reward-init-wizard/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md            # (deferred — minimal data-model can be inlined here; will author with tasks.md if speckit-tasks needs it)
|-- quickstart.md            # (deferred — same)
|-- contracts/               # (deferred — CLI contract is small enough to live in the spec's Operator Path section)
|-- checklists/
|   `-- requirements.md
`-- tasks.md                  # (to be authored by speckit-tasks after this plan passes review)

lib/Amaru/Treasury/
|-- Tx/
|   `-- StakeRewardInitWizard.hs              # NEW (Answers + Env + 2 translations + Error)
|-- Cli/
|   `-- StakeRewardInitWizard.hs              # NEW (parser + 2 subcommand runners)
|-- Cli.hs                                    # +1 subcommand dispatch
`-- (no changes to IntentJSON.hs, Build.hs, Devnet/*Init.hs, Build/StakeRewardInit.hs)

app/amaru-treasury-tx/Main.hs                 # +1 dispatch case
amaru-treasury-tx.cabal                       # +2 exposed modules
README.md                                     # operator path updated
docs/local-devnet-smoke.md                    # operator path updated
test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs                  # NEW (Slice 1)
test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs                         # NEW (Slice 2; round-trips, extended in 3)
test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs             # NEW (Slice 2; refined in 3)
test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNoSimulationSpec.hs             # NEW (Slice 4; grep enforcement, unit test only)
test/golden/Support/StakeRewardInitWizardFixtures.hs                             # NEW (Slice 2; derives wizard fixtures from Support.StakeRewardInitFixtures; extended in 3)
test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardScriptAccountSpec.hs          # NEW (Slice 2)
test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardPlainAccountSpec.hs           # NEW (Slice 3)
test/fixtures/stake-reward-init-wizard/
    registry.json                             # shared between both sub-actions
    script-account-answers.json
    script-account-intent.json
    plain-account-answers.json
    plain-account-intent.json
```

No changes to `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/StakeRewardInit.hs`, or `lib/Amaru/Treasury/Devnet/*Init.hs`. SC-006 enforces the `tx-build` unchanged invariant; SC-007 enforces the no-internal-simulation invariant; FR-014 enforces the `SmokeSpec` unchanged invariant.

## Risks & Mitigations

- **Risk**: The resolver shape (network probe, wallet UTxO query, upper-bound-slot) duplicates code already in `RegistryInitWizard`, `WithdrawWizard`, and `SwapWizard`. Copy-paste drift across **four** wizard families is a real concern (this PR makes it four).
  - **Mitigation**: Reuse `Amaru.Treasury.Tx.SwapWizard`'s shared helpers (`selectWallet`, `addrNetwork`, etc.) directly via import, exactly as `RegistryInitWizard` does. Anything not already factored out stays a local function; defer a shared `Amaru.Treasury.Tx.WizardCommon` module to a separate refactor PR (not in scope for #159). If Slice 2 finds itself copy-pasting more than two lines from `RegistryInitWizard.hs`, the orchestrator pauses and decides whether to extract; default action is "import what's exported, copy what's local, don't refactor inside #159."

- **Risk**: The shared `registry.json` test fixture (Slice 2) may drift from what a real `registry-init-wizard reference-scripts` submission would produce in practice. If the wizard test fixture has fields the live registry doesn't, the wizard could quietly start depending on them.
  - **Mitigation**: The test fixture is built by `Support.StakeRewardInitWizardFixtures` (Slice 2) from the same underlying material as `Support.StakeRewardInitFixtures.scriptAccountFixture` / `plainAccountFixture` (which #157 already uses for the library-core goldens). The wizard fixture must round-trip through `readDevnetStakeRewardRegistry` cleanly. If the live registry shape changes (currently `phase`/`network`/`anchors`/`scripts`), `readDevnetStakeRewardRegistry` is the single source of truth — both the live submitter and the wizard fixture parse via it. The mitigation is: do not hand-roll JSON; encode `DevnetStakeRewardRegistry` through the same JSON path the live submitter writes (extracting from `Support.RegistryInitFixtures`'s reference-scripts fixture material if a co-derivation helper is practical; falling back to a hand-rolled JSON that the test asserts parses cleanly via `readDevnetStakeRewardRegistry`).

- **Risk**: The `--funding-seed-txin` parser shape already exists in the codebase — reinventing it would be wasted work, and inconsistency would be worse.
  - **Mitigation**: It exists at `Amaru.Treasury.LedgerParse.txInFromText :: Text -> Either String TxIn` and is already used by `RegistryInitWizard`'s `mint` / `reference-scripts` parsers (#158). Slice 1's parser wires it through optparse-applicative's `eitherReader`.

- **Risk**: Slice 4's "no internal simulation" grep enforcement is a moving target if anyone later legitimately wants to import a construction core into the wizard.
  - **Mitigation**: A single hspec unit test (`StakeRewardInitWizardNoSimulationSpec`) reads the wizard module sources and asserts no occurrences of the two `*Core` symbol names. No parallel `gate.sh` step — `./gate.sh` runs the suite. The override is owned by #163's resolution, not by silently breaking the test. Strip Haskell comments before the grep (same pattern as `RegistryInitWizardNoSimulationSpec`).

- **Risk**: Slice 2's resolver layer adds **three** new orthogonal failure modes at once (network guard, registry-parse, wallet shortfall). A single slice could grow unwieldy.
  - **Mitigation**: All three are covered by **unit tests at the resolver layer** (no golden fixture work needed for them). The pure translation function is the same shape as #158's `registryInitSeedSplitToIntent` — small, focused, easy to review. If Slice 2 grows past ~400 added lines, the orchestrator may split it: Slice 2a "resolver + script-account + network guard"; Slice 2b "registry-parse error variants + tests." Default plan is "ship as one slice"; tasks.md will reflect the default and call out the split-fallback explicitly.

- **Risk**: NFR-007 (no enforced ordering between subcommands) could be silently violated by a future change that adds a sanity check like "is the other reward account already registered?"
  - **Mitigation**: NFR-007 is not enforced by a grep test — it's an architectural posture. The orchestrator review at every slice checks for any chain query in the resolver other than the network probe + standard wallet query. If Slice 2's resolver grows to "check chain for the other reward account," that's caught at review.

## Complexity Tracking

No constitution violations. The principal complexity is:

1. Replicating the resolver shape from `RegistryInitWizard` without inviting a premature abstraction — mitigated by deferring the shared-helper extraction.
2. The shared `registry.json` test fixture (Slice 2) needs to round-trip through `readDevnetStakeRewardRegistry` cleanly while staying co-derived with `Support.StakeRewardInitFixtures`. The mitigation above names the concrete path: build the JSON via the same `Support.RegistryInitFixtures` reference-scripts material the production module's parser already accepts.
3. Slice 2 has three orthogonal resolver-layer failure modes (network, registry-parse, wallet shortfall). The mitigation above names the split-fallback if the slice grows too large.

All other concerns (parser reuse, no-simulation grep, network-safety) have precedents in #158 and are direct copies of established patterns.
