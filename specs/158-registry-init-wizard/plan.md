# Implementation Plan: registry-init-wizard

**Branch**: `158-registry-init-wizard` | **Date**: 2026-05-18 | **Spec**: [spec.md](./spec.md)
**Issue**: [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessor**: [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162)
**Parked Follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — resumable client state; promotes this stupid baseline to a real wizard

## Status

**Current**: Branch + draft PR ([#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165)) + `gate.sh` in place. `spec.md` and requirements checklist committed and reviewed. This plan is the contract subagents read before slice dispatch.

**Blockers**: None. #157 (PR #162) already shipped the three `SomeTreasuryIntent` variants (`RegistryInitSeedSplit`, `RegistryInitMint`, `RegistryInitReferenceScripts`) this wizard targets, plus the `requireDevnet` guard in the `tx-build` dispatcher.

## Implementation Ownership

The orchestrator owns this specification, plan, task breakdown, `gate.sh`, contracts, quickstart, local review, final PR metadata, and docs alignment. Behavior-changing code slices are implemented by one subagent at a time after this plan and `tasks.md` have passed local review.

Each subagent receives a narrow brief naming exact task ids, owned files / modules, forbidden scope, RED proof, GREEN proof, and the gate to run. The orchestrator reviews the returned diff, reruns `./gate.sh` locally, updates `tasks.md` (`[X] T### (commit: <sha>)`) plus PR metadata, and only then starts the next subagent.

## Parent Carry-Forward Invariants (from #156)

- Shipped CLI bootstrap surface produces unsigned txs only.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/RegistryInit.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface.
- Library proof (`SmokeSpec`) survives every child; CLI proof (`smoke.sh`) lands in #161.
- Network safety: every CLI bootstrap entry fails closed for non-DevNet networks.

## Deliberate override: wizard-vs-stupid-command

The parent #156 invariant *"a wizard only asks the operator for human decisions"* is **explicitly overridden** for #158 (and by extension #159 / #160). Operator-typed inter-tx state is the design, by deliberate choice. The principle remains the design goal for [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163), which promotes the stupid baseline to a resumable wizard. Memory `feedback_wizard_vs_stupid_command` documents the rule; this plan documents the override.

## Summary

Add `Amaru.Treasury.Tx.RegistryInitWizard` (typed answers + pure translation per sub-action) and `Amaru.Treasury.Cli.RegistryInitWizard` (optparse-applicative parser with three subcommands + IO runner per sub-action), wired into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Each subcommand parses its operator flags, performs standard resolver work (`verifyRegistry`, wallet UTxO query, upper-bound-slot sampling, mirroring `WithdrawWizard`), runs a pure translation that maps `Answers + Env → SomeTreasuryIntent`, and writes one bare `SomeTreasuryIntent` JSON to `--out`. No cross-step simulation; inter-tx values come from operator flags. Three golden CBOR equivalence proofs (one per sub-action) hold the wizard-produced intent → `tx-build` byte-equal to the library core's output on the same logical inputs.

**FR-001 (subcommand emits one intent JSON) is satisfied incrementally across Slices 1–4.** Slice 1 ships parser scaffolding and a TODO-stub runner for all three subcommands (gate green, `--help` works, runtime path exits non-zero). Slice 2 makes `seed-split` functional. Slice 3 makes `mint` functional. Slice 4 makes `reference-scripts` functional. Operators cannot use the wizard until Slice 4 lands; this is the deliberate cost of vertical bisect-safe slicing. The PR ships all four slices together.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients` (Provider/Submitter), `cardano-tx-tools`, `cardano-ledger-conway`, `aeson` (intent JSON shape from #157), `optparse-applicative` (parser).
**Storage**: filesystem only — operator types flags, wizard writes one intent JSON per invocation.
**Testing**: Hspec unit + golden suites; round-trip property checks reusing the harness from #157's `RegistryInitIntentSpec`; `just schema-check` (unchanged — no schema delta).
**Target Platform**: Local Linux Nix development shell.
**Project Type**: Haskell CLI/library.
**Performance Goals**: No change in CLI parser construction cost or `tx-build` build time relative to existing wizards.
**Constraints**: Bisect-safe per commit; `./gate.sh` green at every HEAD; mainnet/preprod fail-closed at the wizard resolver layer; **no internal cross-step simulation** (NFR-006); wizard source must contain zero references to `buildSeedSplitCore` / `buildRegistryNftsCore` / `buildReferenceScriptsCore`.
**Scale/Scope**: Three subcommands, three pure translation functions, three goldens, three round-trip properties, parser test, network-safety test, docs alignment.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The wizard's emitted intents produce, through `tx-build`, the same CBOR the library cores produce; on-chain behavior is unchanged.

**II. Pure builders, impure shell**: PASS. The wizard's pure translation per sub-action returns `Either RegistryInitError SomeTreasuryIntent` and does no IO. The resolver layer's IO (chain queries) is identical in shape to `WithdrawWizard`'s resolver.

**III. Pluggable data source, local-node default**: PASS. The resolver uses the same `Provider`-based query helpers `WithdrawWizard` uses; backend swap is at the existing seam, not in the wizard.

**IV. Build, never sign or submit**: PASS. The wizard emits `SomeTreasuryIntent` JSON. Signing and submission stay on `witness` / `submit`. The wizard does NOT call `tx-build` internally (NFR-005).

**V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)**: PASS. Three goldens (one per sub-action) prove byte-for-byte CBOR equivalence between the wizard-produced intent → `tx-build` and the library core's output. RED + GREEN are paired in one reviewed commit per slice.

**VI. Hackage-ready Haskell**: PASS. Explicit exports, Haddock, fourmolu, hlint, `cabal check`, `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata body-shape change. The wizard reuses `WithdrawWizard`'s optional rationale flag set verbatim.

## Live-Boundary Diagnostic

Per the resolve-ticket diagnostic *"what system boundary does this exercise that the unit suite cannot?"*:

- The behavior changes are: a new CLI parser with three subcommands, a resolver that queries the chain for the wallet/registry/slot (same shape as `WithdrawWizard`'s resolver — already exercised by unit + golden coverage), and a pure translation per sub-action.
- The byte-identical CBOR equivalence proof (three goldens) is the parity gate. It holds "library-built CBOR" and "wizard-built-via-intent-and-tx-build CBOR" fixed against each other for every sub-action.
- The **live operator path** through the new subcommands is proved by the bash `smoke.sh` in #161. Deferring it here is explicit and matches the parent's two-proof-layer plan.
- The library proof at the live boundary continues to be `SmokeSpec` against `withDevnet`, which this PR preserves unchanged.

Plan-review conclusion: no extra live-boundary smoke is required in `gate.sh` for #158. If a slice introduces a new live fetch outside what `WithdrawWizard`'s resolver does, the slice's subagent brief must add a live-boundary check before the slice is reviewable.

## Vertical Review Slices

Each slice is one bisect-safe commit, dispatched as one subagent run, with RED + GREEN in the same commit. Slice numbers map to task ranges in `tasks.md`.

1. **Slice 1 — Wizard library scaffolding + CLI parser + parser test (RED + GREEN, one commit).** Create `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` with the three `Answers` records (`RegistryInitSeedSplitAnswers`, `RegistryInitMintAnswers`, `RegistryInitReferenceScriptsAnswers`) and `RegistryInitError`. Create `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` with `registryInitWizardOptsP` exposing three subcommands and the runner stub. Wire into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Update `amaru-treasury-tx.cabal` to expose the new modules. RED: parser test asserting (a) `amaru-treasury-tx registry-init-wizard {seed-split | mint | reference-scripts}` parse correctly, (b) `--help` outputs list the required flags (including the inter-tx flags for `mint` and `reference-scripts`), (c) malformed `--owner-key-hash` (not 56 hex chars) is rejected at the parser, (d) malformed `--scopes-seed-txin` / `--registry-seed-txin` / `--funding-seed-txin` (not `<txid64hex>#<word16>`) is rejected at the parser, (e) `--out` pointing at a path whose parent directory does not exist surfaces a typed error before any work happens, (f) `--out` pointing at an existing file without `--force` surfaces a typed conflict error. GREEN: parser test passes; `just ci` and `./gate.sh` green. No translation logic yet; the runner stub prints a TODO error and exits non-zero. Owner-key-hash parser uses `Amaru.Treasury.LedgerParse.keyHashFromHex`; TxIn parser uses `Amaru.Treasury.LedgerParse.txInFromText`.

   Owned files:
   `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` (new — Answers + RegistryInitError),
   `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` (new — parser + runner stub),
   `lib/Amaru/Treasury/Cli.hs` (wire subcommand),
   `app/amaru-treasury-tx/Main.hs` (wire runner),
   `amaru-treasury-tx.cabal` (expose new modules),
   `test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs` (new).

2. **Slice 2 — Resolver + seed-split pure translation + golden + devnet network guard (RED + GREEN, one commit).** Add `RegistryInitEnv` and the resolver for `seed-split`: `verifyRegistry`, wallet UTxO query, upper-bound-slot sampling. **Mandatory: add the devnet-only guard at the resolver layer** (FR-007 / SC-007 / spec User Story 3). The existing wizards (Withdraw/Disburse/Swap) accept any valid network family — this is a **new** constraint specific to bootstrap actions, and `Build.hs:213 requireDevnet` already enforces it at `tx-build --intent` time so this layer is defense-in-depth / fail-fast UX. The guard typed-fails with `RegistryInitNonDevnetNetwork` before any chain query happens; covered by a unit test that drives the resolver against a `mainnet` / `preprod` / `preview` input and asserts the typed error. Implement `registryInitSeedSplitToIntent :: RegistryInitEnv -> RegistryInitSeedSplitAnswers -> Either RegistryInitError SomeTreasuryIntent` (pure). Wire the runner's `seed-split` arm to: resolve env → pure translation → `encodeSomeTreasuryIntent` → write to `--out`. Add a small test-support helper `test/golden/Support/RegistryInitWizardFixtures.hs` that **derives wizard `Answers + Env` from the same underlying material `Support.RegistryInitFixtures` (#157) already uses for library-core goldens**, so the two sides cannot drift. RED: (a) golden test asserting that the wizard's intent → `tx-build` produces CBOR bytes identical to `buildSeedSplitCore`'s output on equivalent inputs; (b) unit test asserting the devnet network guard fires a typed error before any chain query; (c) unit test asserting the wallet-shortfall case surfaces `RegistryInitWalletShortfall` from the resolver (not from `tx-build`); the resolver layer's "shortfall" detection is the same shape as `WithdrawWizard`'s `WithdrawResolverEmptyWalletUtxos` — empty pure-ADA UTxOs set, not balance simulation. GREEN: goldens + unit tests + round-trip property for the `seed-split` JSON pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` (add resolver + seed-split translation + devnet network guard),
   `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` (wire seed-split runner),
   `test/golden/Support/RegistryInitWizardFixtures.hs` (new — wizard fixtures derived from `Support.RegistryInitFixtures`),
   `test/golden/Amaru/Treasury/Tx/RegistryInitWizardSeedSplitSpec.hs` (new),
   `test/fixtures/registry-init-wizard/seed-split-answers.json` (new),
   `test/fixtures/registry-init-wizard/seed-split-intent.json` (new golden output),
   `test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs` (new — round-trip for seed-split),
   `test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs` (new — devnet guard for all three subcommands; mint and reference-scripts cases are scaffolded with placeholder Answers in Slice 2, refined in Slices 3 and 4).

3. **Slice 3 — Mint pure translation + golden (RED + GREEN, one commit).** Implement `registryInitMintToIntent :: RegistryInitEnv -> RegistryInitMintAnswers -> Either RegistryInitError SomeTreasuryIntent` (pure). The mint answers carry operator-typed `--scopes-seed-txin`, `--registry-seed-txin`, `--owner-key-hash` — these are validated at the parser (hex-28 format for owner key hash; `<txid#ix>` for TxIns) and baked verbatim into the produced intent's `RegistryInitMintInputs` payload. Wire the `mint` arm. RED: golden equivalence test for `buildRegistryNftsCore`. GREEN: golden + round-trip pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` (add mint translation),
   `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` (wire mint runner; add TxIn / hex-28 parsers if not already present),
   `test/golden/Amaru/Treasury/Tx/RegistryInitWizardMintSpec.hs` (new),
   `test/fixtures/registry-init-wizard/mint-answers.json` (new),
   `test/fixtures/registry-init-wizard/mint-intent.json` (new),
   `test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs` (extend with mint round-trip).

4. **Slice 4 — Reference-scripts pure translation + golden (RED + GREEN, one commit).** Implement `registryInitReferenceScriptsToIntent`. Reference-scripts answers carry operator-typed `--scopes-seed-txin`, `--registry-seed-txin`, `--funding-seed-txin`. Wire the `reference-scripts` arm. RED: golden equivalence test for `buildReferenceScriptsCore`. GREEN: golden + round-trip pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` (add reference-scripts translation),
   `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` (wire reference-scripts runner),
   `test/golden/Amaru/Treasury/Tx/RegistryInitWizardReferenceScriptsSpec.hs` (new),
   `test/fixtures/registry-init-wizard/reference-scripts-answers.json` (new),
   `test/fixtures/registry-init-wizard/reference-scripts-intent.json` (new),
   `test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs` (extend with reference-scripts round-trip).

5. **Slice 5 — No-simulation grep enforcement (RED + GREEN, one commit).** Add a unit test that reads the wizard module sources (`lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` and `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`) via `Data.Text.IO.readFile` and asserts zero occurrences of `buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore` (NFR-006 / SC-007). **Unit test only** — no parallel `gate.sh` grep step (`./gate.sh` runs the suite). The network guard, parser edge cases, `--force` semantics, parent-dir-missing, and wallet-shortfall tests are owned by Slices 1–4 (see those slices' RED lists). Slice 5 is intentionally narrow — one grep test, one commit. RED: the test runs and fails the moment any wizard module mentions a `*Core` symbol. GREEN: the wizard modules don't mention any, so the test passes; `./gate.sh` green.

   Owned files:
   `test/unit/Amaru/Treasury/Tx/RegistryInitWizardNoSimulationSpec.hs` (new — grep enforcement, unit test only).

6. **Slice 6 — Documentation alignment (orchestrator-owned, single commit).** Update `README.md` and `docs/local-devnet-smoke.md` to describe `amaru-treasury-tx registry-init-wizard {seed-split | mint | reference-scripts}` as the operator entry, show the three invocations with operator-typed inter-tx flags, carry the explicit "unsafe inter-step carry" warning, and forward-reference #161 (bash smoke) and #163 (resumable client state). Refresh the PR body to match.

   Owned files:
   `README.md`,
   `docs/local-devnet-smoke.md`,
   `specs/158-registry-init-wizard/tasks.md` (tick remaining `[ ]` items if any).

7. **Slice 7 — Drop `gate.sh` & ready (orchestrator-owned).**
   `chore: drop gate.sh (ready for review)`; `gh pr ready`.

## Project Structure

```text
specs/158-registry-init-wizard/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- registry-init-wizard-cli.md
|-- checklists/
|   `-- requirements.md
`-- tasks.md

lib/Amaru/Treasury/
|-- Tx/
|   `-- RegistryInitWizard.hs                 # NEW (Answers + Env + 3 translations + Error)
|-- Cli/
|   `-- RegistryInitWizard.hs                 # NEW (parser + 3 subcommand runners)
|-- Cli.hs                                    # +1 subcommand dispatch
`-- (no changes to IntentJSON.hs, Build.hs, Devnet/*Init.hs)

app/amaru-treasury-tx/Main.hs                 # +1 dispatch case
amaru-treasury-tx.cabal                       # +2 exposed modules
README.md                                     # operator path updated
docs/local-devnet-smoke.md                    # operator path updated
test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs                  # NEW (Slice 1; extended in 3 + 4)
test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs                         # NEW (Slice 2; round-trips, extended in 3 + 4)
test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs             # NEW (Slice 2; refined in 3 + 4)
test/unit/Amaru/Treasury/Tx/RegistryInitWizardNoSimulationSpec.hs             # NEW (Slice 5; grep enforcement, unit test only)
test/golden/Support/RegistryInitWizardFixtures.hs                             # NEW (Slice 2; derives wizard fixtures from Support.RegistryInitFixtures)
test/golden/Amaru/Treasury/Tx/RegistryInitWizardSeedSplitSpec.hs              # NEW (Slice 2)
test/golden/Amaru/Treasury/Tx/RegistryInitWizardMintSpec.hs                   # NEW (Slice 3)
test/golden/Amaru/Treasury/Tx/RegistryInitWizardReferenceScriptsSpec.hs       # NEW (Slice 4)
test/fixtures/registry-init-wizard/
    seed-split-answers.json
    seed-split-intent.json
    mint-answers.json
    mint-intent.json
    reference-scripts-answers.json
    reference-scripts-intent.json
```

No changes to `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/Build.hs`, or `lib/Amaru/Treasury/Devnet/*Init.hs`. SC-006 enforces the `tx-build` unchanged invariant; SC-007 enforces the no-internal-simulation invariant; FR-013 enforces the `SmokeSpec` unchanged invariant.

## Risks & Mitigations

- **Risk**: The resolver shape (registry verification, wallet UTxO query, upper-bound-slot) duplicates code already in `WithdrawWizard` and `SwapWizard`. Copy-paste drift is a real concern.
  - **Mitigation**: Reuse `Amaru.Treasury.Tx.WithdrawWizard`'s shared helpers (`registryViewFromVerified`, `selectWallet`, `addrNetwork`) directly via import. Anything not already factored out gets factored into a small shared module (`Amaru.Treasury.Tx.WizardCommon.hs`) only if Slice 2 needs a third caller of a private helper. Default to importing; abstract only if forced.

- **Risk**: Golden fixtures hand-rolled from the wizard's `Answers + Env` may drift from what `Support/RegistryInitFixtures.hs` (#157's fixture helper) uses for the matching library-core golden.
  - **Mitigation**: Slice 2 owns the new `test/golden/Support/RegistryInitWizardFixtures.hs` helper that materializes both the library-core fixture and the wizard-`Answers + Env` fixture from the same underlying inputs. Slices 3 and 4 extend the helper for `mint` and `reference-scripts`. The parity proof then holds both sides on the same source of truth.

- **Risk**: The operator-typed inter-tx flag parsers (`<txid#ix>`, hex-28) might already exist in the codebase — reinventing them would be wasted work, and inconsistency would be worse.
  - **Mitigation**: They exist at `Amaru.Treasury.LedgerParse.txInFromText :: Text -> Either String TxIn` and `Amaru.Treasury.LedgerParse.keyHashFromHex :: Text -> Either String (KeyHash Witness)`. Slice 1's parser test wires them through optparse-applicative `eitherReader`; Slice 3 reuses them without re-implementing.

- **Risk**: Slice 5's "no internal simulation" grep enforcement is a moving target if anyone later legitimately wants to import a construction core into the wizard.
  - **Mitigation**: A single hspec unit test (`RegistryInitWizardNoSimulationSpec`) reads the wizard module sources and asserts no occurrences of the three `*Core` symbol names. No parallel `gate.sh` step — `./gate.sh` runs the suite. The override is owned by #163's resolution, not by silently breaking the test.

## Complexity Tracking

No constitution violations. The principal complexity is:

1. Replicating the resolver shape from `WithdrawWizard` without inviting a premature abstraction — mitigated by deferring the shared-helper extraction until Slice 2 actually needs it.
2. The `--owner-key-hash <hex28>` and `<txid#ix>` parser shapes — these have precedents elsewhere in the codebase; mitigated by Slice 3's reuse mandate.
