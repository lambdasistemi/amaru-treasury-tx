# Implementation Plan: governance-withdrawal-init-wizard

**Branch**: `160-governance-withdrawal-init-wizard` | **Date**: 2026-05-19 | **Spec**: [spec.md](./spec.md)
**Issue**: [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessors**:
- [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162) (shipped the two `GovernanceWithdrawalInit*` intent variants this wizard targets, the matching `Translated`/`Inputs` records in `lib/Amaru/Treasury/IntentJSON.hs`, plus the `requireDevnet` guard in the `tx-build` dispatcher at `lib/Amaru/Treasury/Build.hs:181-196`)
- [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158) — merged via PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165) (architectural template — three subcommands, parser/golden/network-guard/no-simulation patterns)
- [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159) — merged via PR [#168](https://github.com/lambdasistemi/amaru-treasury-tx/pull/168) (**direct architectural and stylistic template for this PR** — two-subcommand structure, registry-artifact parse, devnet network guard, no-simulation grep, fixture co-derivation pattern)
**Sibling Successor**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) — bash `smoke.sh` CLI proof
**Parked Follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — resumable client state; supersedes this stupid baseline with a real wizard. A future "wizard reads key hashes from the same vault `witness` uses" upgrade also lives in the parked space — its prerequisite (a vault-manifest sidecar so labels and key hashes are queryable without the passphrase) is out of scope for #160.

## Status

**Current**: Branch + draft PR ([#169](https://github.com/lambdasistemi/amaru-treasury-tx/pull/169)) + `gate.sh` in place. `spec.md` committed and approved at commit [`cb57ac9b`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/cb57ac9b). This plan is the contract subagents read before slice dispatch.

**Blockers**: None. #157 already shipped the two `SomeTreasuryIntent` variants (`GovernanceWithdrawalInitProposal`, `GovernanceWithdrawalInitMaterialization`), the matching `Translated`/`Inputs` records, the translators (`translateGovernanceWithdrawalInitProposal`, `translateGovernanceWithdrawalInitMaterialization`) in `lib/Amaru/Treasury/IntentJSON.hs`, the `requireDevnet` guard in the `tx-build` dispatcher, and the artifact loaders (`readDevnetGovernanceWithdrawalRegistry`, `readDevnetGovernanceStakeRewardAccounts`) + cross-validator (`validateGovernanceWithdrawalPrerequisites`) in `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`. #158 and #159 shipped the architectural template (parser + resolver + golden + network guard + no-simulation grep).

## Implementation Ownership

The orchestrator owns this specification, plan, task breakdown, `gate.sh`, contracts, quickstart, local review, final PR metadata, and docs alignment. Behavior-changing code slices are implemented one at a time after this plan and `tasks.md` have passed local review.

**Dispatch backend: tmux pane worker (Backend B per resolve-ticket).** The user requested visibility. The orchestrator runs the `tmux-pane-worker` protocol with worker ids of the form `gov-init/<slice-slug>` under runtime root `/tmp/gov-init/`. Each slice's pane worker is a slice executor (not a sub-orchestrator) — the orchestrator owns spec/plan/tasks/PR metadata; the pane worker owns exactly one bisect-safe commit per slice. STATUS.md is the orchestrator's primary monitoring channel; `WIP.md` in the worktree root is the worker-internal implementation log per the resolve-ticket invariants. The brief contract enforces the "no `AskUserQuestion` for orchestrator-bound decisions" clause — workers use Q-files under `/tmp/gov-init/<worker-id>/questions/` and poll for answers.

Each slice receives a narrow brief naming exact task ids, owned files / modules, forbidden scope, RED proof, GREEN proof, and the gate to run. The orchestrator reviews the returned diff in the worktree, reruns `./gate.sh` locally, amends the slice commit to also check off the matching `tasks.md` boxes (resolve-ticket's stamping pattern), and only then dispatches the next slice. STATUS.md tailing during the run catches scope creep / RED-skipping early.

## Parent Carry-Forward Invariants (from #156)

- Shipped CLI bootstrap surface produces unsigned txs only.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` and the cores it pulls from `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface.
- Library proof (`SmokeSpec`) survives every child; CLI proof (`smoke.sh`) lands in #161.
- Network safety: every CLI bootstrap entry fails closed for non-DevNet networks.

## Deliberate override: wizard-vs-stupid-command

The parent #156 invariant *"a wizard only asks the operator for human decisions"* is **explicitly overridden** for #160, mirroring #158's and #159's overrides. Operator-typed inter-tx state (the registry + stake/reward-accounts artifact paths, a funding-seed TxIn per invocation, the observed rewards balance for materialization) is the design, by deliberate choice. The two governance key hashes and the CIP-1694 anchor hash are *also* operator-typed for the additional reason captured in NFR-008: the wizard touches no key material at all (no signing key reads, no verification key reads, no vault reads, no passphrase prompts), and the existing vault format encrypts the entire identity manifest, so vault-label lookup without the passphrase is not achievable in the current format. Source-of-truth between declared hashes and signing-time identities is the operator's responsibility, surfaced as a typed required-signer failure at `witness` time. The full principle remains the design goal for [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163); the vault-manifest sidecar that would let a future wizard query key hashes without a passphrase is its own ticket. Memory `feedback_wizard_vs_stupid_command` documents the rule; this plan documents the override.

## Summary

Add `Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard` (typed answers + pure translation per sub-action) and `Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard` (optparse-applicative parser with two subcommands + IO runner per sub-action), wired into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Each subcommand parses its operator flags, parses the supplied `--registry` file via the existing `readDevnetGovernanceWithdrawalRegistry`, parses the supplied `--stake-reward-accounts` file via the existing `readDevnetGovernanceStakeRewardAccounts`, cross-validates the two artifacts via the existing `validateGovernanceWithdrawalPrerequisites`, performs standard resolver work (network probe, wallet UTxO query, upper-bound-slot sampling — same shape as `StakeRewardInitWizard`), runs a pure translation that maps `Answers + Env → SomeTreasuryIntent`, and writes one bare `SomeTreasuryIntent` JSON to `--out`. No cross-step simulation; no registry chain re-verification; no chain query for the materialization rewards balance; inter-tx values come from the two artifacts + `--funding-seed-txin` + the operator-typed key hashes + the operator-typed rewards balance. Two golden CBOR equivalence proofs (one per sub-action) hold the wizard-produced intent → `tx-build` byte-equal to the library core's output on the same logical inputs.

For `proposal` specifically, the resolver adds a **deposit-aware wallet-shortfall check** that sums `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` from the pparams projection (already in the chain context the resolver constructs) and fails closed before any file is written — preempting the otherwise-generic "build failure" at `tx-build` time for the most expensive bootstrap step (100,000 ADA on mainnet, configurable per-network on DevNet).

**FR-001 (subcommand emits one intent JSON) is satisfied incrementally across Slices 1–3.** Slice 1 ships parser scaffolding and a TODO-stub runner for both subcommands (gate green, `--help` works, runtime path exits non-zero). Slice 2 makes `proposal` functional. Slice 3 makes `materialization` functional. Operators cannot use the wizard until Slice 3 lands; this is the deliberate cost of vertical bisect-safe slicing. The PR ships all slices together.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients` (Provider/Submitter), `cardano-tx-tools`, `cardano-ledger-conway`, `aeson` (intent JSON shape from #157), `optparse-applicative` (parser).
**Storage**: filesystem only — operator types flags + two artifact paths, wizard writes one intent JSON per invocation. No key material reads of any kind (NFR-008).
**Testing**: Hspec unit + golden suites; round-trip property checks reusing the harness from #157's `GovernanceWithdrawalInitIntentSpec`; `just schema-check` (unchanged — no schema delta).
**Target Platform**: Local Linux Nix development shell.
**Project Type**: Haskell CLI/library.
**Performance Goals**: No change in CLI parser construction cost or `tx-build` build time relative to existing wizards.
**Constraints**: Bisect-safe per commit; `./gate.sh` green at every HEAD; mainnet/preprod/preview fail-closed at the wizard resolver layer; no chain re-verification of either artifact; no chain query for the materialization rewards balance; **no internal cross-step simulation** (NFR-006); **no key-material reads of any kind** (NFR-008); wizard source must contain zero references to `buildGovernanceWithdrawalProposalCore` / `buildGovernanceWithdrawalMaterializationCore`; no enforced ordering between subcommands (NFR-007).
**Scale/Scope**: Two subcommands, two pure translation functions, two goldens, two round-trip properties, parser test, network-safety test, deposit-aware shortfall test, no-simulation grep, no-key-material grep, no-chain-query grep, docs alignment (operator path + witness contract + DRep-equals-proposer caveat + deposit reasoning).

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The wizard's emitted intents produce, through `tx-build`, the same CBOR the library cores produce; on-chain behavior is unchanged. The bash recipes do not include governance-withdrawal-init as a separate concept (it was added in the Haskell stack); the constitution's "tie-break" rule is therefore inapplicable to this PR.

**II. Pure builders, impure shell**: PASS. The wizard's pure translation per sub-action returns `Either GovernanceWithdrawalInitError SomeTreasuryIntent` and does no IO. The resolver layer's IO (chain queries + artifact file reads) is identical in shape to `StakeRewardInitWizard`'s resolver, plus the additional `readDevnetGovernanceStakeRewardAccounts` parse.

**III. Pluggable data source, local-node default**: PASS. The resolver uses the same `Provider`-based query helpers `StakeRewardInitWizard` uses; backend swap is at the existing seam, not in the wizard. The two artifact-file reads are `IO (Either String ...)` via the existing module-level functions — no new IO seam introduced.

**IV. Build, never sign or submit**: PASS. The wizard emits `SomeTreasuryIntent` JSON. Signing and submission stay on `witness` / `attach-witness` / `submit`. The wizard does NOT call `tx-build` internally (NFR-005). The wizard ALSO does not touch key material of any kind (NFR-008) — operator-declared hashes are pass-through.

**V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)**: PASS. Two goldens (one per sub-action) prove byte-for-byte CBOR equivalence between the wizard-produced intent → `tx-build` and the library core's output. RED + GREEN are paired in one reviewed commit per slice.

**VI. Hackage-ready Haskell**: PASS. Explicit exports, Haddock, fourmolu, hlint, `cabal check`, `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata body-shape change. The proposal sub-action carries the CIP-1694 governance anchor (URL + 32-byte content hash) inside the standard `ProposalProcedure`, not as Label-1694 transaction metadata; this is handled by the library core, not the wizard, and is not a Label-1694 surface.

## Live-Boundary Diagnostic

Per the resolve-ticket diagnostic *"what system boundary does this exercise that the unit suite cannot?"*:

- The behavior changes are: a new CLI parser with two subcommands and the new key-hash + anchor-hash + amount flags, a resolver that queries the chain for the network/wallet/slot/pparams (same shape as `StakeRewardInitWizard`'s resolver — already exercised by unit + golden coverage), two artifact-file parses (using the existing `readDevnetGovernanceWithdrawalRegistry` and `readDevnetGovernanceStakeRewardAccounts`), a cross-validation pass between the two artifacts, a deposit-aware wallet-shortfall check using the pparams already in the chain context, and a pure translation per sub-action.
- The byte-identical CBOR equivalence proof (two goldens) is the parity gate. It holds "library-built CBOR" and "wizard-built-via-intent-and-tx-build CBOR" fixed against each other for every sub-action.
- The **live operator path** through the new subcommands is proved by the bash `smoke.sh` in #161. Deferring it here is explicit and matches the parent's two-proof-layer plan.
- The library proof at the live boundary continues to be `SmokeSpec` against `withDevnet`, which this PR preserves unchanged.
- The two artifact-file reads are deterministic file IO + JSON parses; no new chain boundary is introduced.
- The network probe at the resolver layer hits the same chain seam `StakeRewardInitWizard` already exercises.
- The deposit-aware shortfall (Slice 2's FR-008) reads `govActionDeposit + stakeDeposit + drepDeposit` fields from the pparams projection already in `ChainContext`. **No new chain seam.** Unit-test coverage with a deterministic fixture pparams asserts the per-component sum and the typed error shape.

Plan-review conclusion: no extra live-boundary smoke is required in `gate.sh` for #160. The new resolver fields (deposits) are projections of the existing chain context; the cross-validation between the two artifacts is pure on parsed values. If a slice introduces a new live fetch outside what `StakeRewardInitWizard`'s resolver does, the slice's worker brief must add a live-boundary check before the slice is reviewable. The CLI/operator live proof is `#161`'s `smoke.sh`.

## Vertical Review Slices

Each slice is one bisect-safe commit, dispatched as one tmux pane worker run, with RED + GREEN in the same commit. Slice numbers map to task ranges in `tasks.md`. Worker id pattern: `gov-init/<slice-slug>`.

1. **Slice 1 — Wizard library scaffolding + CLI parser + parser test (RED + GREEN, one commit).** Worker `gov-init/scaffold`. Create `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` with the two `Answers` records (`GovernanceWithdrawalInitProposalAnswers`, `GovernanceWithdrawalInitMaterializationAnswers`) and `GovernanceWithdrawalInitError`. Create `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs` with `governanceWithdrawalInitWizardOptsP` exposing two subcommands and the runner stub. Wire into `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`. Update `amaru-treasury-tx.cabal` to expose the new modules. RED: parser test asserting (a) `amaru-treasury-tx governance-withdrawal-init-wizard {proposal | materialization}` parse correctly, (b) `--help` outputs list the required flags per subcommand — both: `--wallet-addr`, `--registry`, `--stake-reward-accounts`, `--funding-seed-txin`, `--out`, optional `--validity-hours`, `--log`, `--force`; `proposal` additionally: `--funding-stake-key-hash`, `--voter-key-hash`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-hash`; `materialization` additionally: `--rewards-lovelace`, (c) malformed `--funding-seed-txin` (not `<txid64hex>#<word16>`) is rejected at the parser, (d) malformed `--funding-stake-key-hash` / `--voter-key-hash` (not exactly 56 hex chars) is rejected at the parser, (e) malformed `--anchor-hash` (not exactly 64 hex chars) is rejected at the parser, (f) zero-or-negative `--withdrawal-amount-lovelace` and `--rewards-lovelace` are rejected at the parser, (g) missing required flags surface typed errors, (h) `--out` pointing at a path whose parent directory does not exist surfaces a typed error before any work happens, (i) `--out` pointing at an existing file without `--force` surfaces a typed conflict error. GREEN: parser test passes; `just ci` and `./gate.sh` green. No translation logic yet; the runner stub prints a TODO error and exits non-zero.

   Owned files:
   `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` (new — Answers + GovernanceWithdrawalInitError + hex-length validator helpers),
   `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs` (new — parser + runner stub),
   `lib/Amaru/Treasury/Cli.hs` (wire subcommand),
   `app/amaru-treasury-tx/Main.hs` (wire runner),
   `amaru-treasury-tx.cabal` (expose new modules),
   `test/unit/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizardParserSpec.hs` (new).

2. **Slice 2 — Resolver + proposal translation + golden + devnet network guard + artifact parses + cross-validation + deposit-aware wallet shortfall (RED + GREEN, one commit).** Worker `gov-init/proposal`. Add `GovernanceWithdrawalInitEnv` and the resolver for `proposal`: network probe, wallet UTxO query, upper-bound-slot sampling, **artifact-file parses via the existing `readDevnetGovernanceWithdrawalRegistry` + `readDevnetGovernanceStakeRewardAccounts`** (which already enforce `phase` and `network` at the file-content level), **cross-validation via the existing `validateGovernanceWithdrawalPrerequisites`**, and the **deposit-aware wallet-shortfall check** (FR-008) that sums `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` from the resolver's pparams projection and fails closed before any file is written when the wallet's pure-ADA balance is below the total. **Mandatory: add the devnet-only chain-probe guard at the resolver layer** (FR-010) — the guard typed-fails with `GovernanceWithdrawalInitNonDevnetNetwork` before any further chain query happens. **The wizard does NOT re-verify either parsed artifact against chain state** — it trusts the operator's `--registry` + `--stake-reward-accounts` commitment after the parse + cross-validation gates. Implement `governanceWithdrawalInitProposalToIntent :: GovernanceWithdrawalInitEnv -> GovernanceWithdrawalInitProposalAnswers -> Either GovernanceWithdrawalInitError SomeTreasuryIntent` (pure). The pure translation must (a) extract `dgwrTreasuryScriptHashText` → `treasuryRewardAccountHash` for the payload, (b) pass through the operator-typed `--funding-stake-key-hash` / `--voter-key-hash` / `--withdrawal-amount-lovelace` / `--anchor-url` / `--anchor-hash` verbatim into the payload, (c) build the wallet block with `wjTxIn = txInText (proposalAnswers.fundingSeedTxIn)` and `wjAddress = wsAddress (reWalletSelection env)`. Wire the runner's `proposal` arm. Add `test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs` that **derives wizard `Answers + Env` from the same underlying material the existing library-core test fixtures use** for governance-withdrawal-init proposal (consult `lib/Amaru/Treasury/Devnet/SmokeSpec.hs` and any existing `Support.GovernanceWithdrawalInitFixtures` to find the canonical fixture inputs and use them), so the two sides cannot drift.

   RED:
   - (a) golden test asserting that the wizard's proposal intent → `tx-build` produces CBOR bytes identical to `buildGovernanceWithdrawalProposalCore`'s output on equivalent inputs;
   - (b) unit test asserting the devnet network guard fires a typed error before any chain query on mainnet / preprod / preview (extends `GovernanceWithdrawalInitWizardNetworkGuardSpec` — both subcommands; materialization arm is scaffolded with placeholder Answers, refined in Slice 3);
   - (c) unit test asserting a missing `--registry` file, an unparseable file, a file with `phase != "registry-init"`, and a file with `network != "devnet"` each surface a typed `GovernanceWithdrawalInitRegistryReadError`;
   - (d) unit test asserting the same four cases for `--stake-reward-accounts` with `phase != "stake-reward-init"`;
   - (e) unit test asserting cross-validation mismatch (`accounts.treasury.scriptHash != registry.treasuryScriptHash`) surfaces a typed `GovernanceWithdrawalInitCrossValidationMismatch`;
   - (f) **deposit-aware wallet-shortfall unit test (FR-008)**: given fixture pparams with deterministic `govActionDeposit`, `stakeDeposit`, `drepDeposit` values and a wallet whose pure-ADA balance is below the sum (`govActionDeposit + stakeDeposit + drepDeposit + estimated-fee`), the resolver fails with `GovernanceWithdrawalInitWalletShortfall` naming each component and their sum, before any file is written.

   GREEN: golden + all unit tests + round-trip property for the proposal JSON pass; `./gate.sh` green.

   Owned files:
   `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` (add resolver + proposal translation + devnet network guard + artifact-parse error variants + cross-validation + deposit-aware shortfall),
   `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs` (wire proposal runner),
   `test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs` (new — wizard fixtures co-derived from the same source the library-core goldens use),
   `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs` (new),
   `test/fixtures/governance-withdrawal-init-wizard/proposal-answers.json` (new),
   `test/fixtures/governance-withdrawal-init-wizard/proposal-intent.json` (new golden output),
   `test/fixtures/governance-withdrawal-init-wizard/registry.json` (new — shared between both sub-actions; matches what a successful `registry-init-wizard reference-scripts` submission would produce),
   `test/fixtures/governance-withdrawal-init-wizard/accounts.json` (new — shared between both sub-actions; matches what a successful `stake-reward-init-wizard` pair would produce),
   `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardSpec.hs` (new — round-trip for proposal; artifact-parse error cases; cross-validation; deposit-aware shortfall),
   `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardNetworkGuardSpec.hs` (new — devnet guard for both subcommands; materialization arm scaffolded in Slice 2, refined in Slice 3).

3. **Slice 3 — Materialization translation + golden + materialization-specific resolver (RED + GREEN, one commit).** Worker `gov-init/materialization`. Implement `governanceWithdrawalInitMaterializationToIntent :: GovernanceWithdrawalInitEnv -> GovernanceWithdrawalInitMaterializationAnswers -> Either GovernanceWithdrawalInitError SomeTreasuryIntent` (pure). The materialization answers carry `--registry`, `--stake-reward-accounts`, `--funding-seed-txin`, and `--rewards-lovelace`. Extract `dgwrTreasuryScriptHashText` → `treasuryRewardAccountHash`, `dgwrTreasuryAddressText` → `treasuryAddress`, `dgwrTreasuryRef` → `treasuryRefTxIn`, `dgwrRegistryRef` → `registryRefTxIn` for the payload; pass through the operator-typed `--rewards-lovelace`. Build the wallet block with the operator-typed funding-seed TxIn (same override pattern as proposal). Materialization-specific shortfall: simpler `min-UTxO + estimated-fee` floor (no governance deposits). Wire the `materialization` arm. RED: golden equivalence test for `buildGovernanceWithdrawalMaterializationCore`; round-trip property for the materialization JSON; extend `GovernanceWithdrawalInitWizardNetworkGuardSpec` to cover the materialization arm with real Answers (refining Slice 2's scaffold); unit test asserting materialization-shortfall does NOT include governance deposits in its sum. GREEN: golden + round-trip + network-guard + shortfall tests pass.

   Owned files:
   `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` (add materialization translation + materialization-specific shortfall),
   `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs` (wire materialization runner),
   `test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs` (extend with materialization fixture derivation),
   `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs` (new),
   `test/fixtures/governance-withdrawal-init-wizard/materialization-answers.json` (new),
   `test/fixtures/governance-withdrawal-init-wizard/materialization-intent.json` (new),
   `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardSpec.hs` (extend with materialization round-trip + simpler-shortfall test),
   `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardNetworkGuardSpec.hs` (refine materialization arm with real Answers).

4. **Slice 4 — Property-enforcement grep tests: no-simulation + no-key-material + no-chain-query for rewards (RED + GREEN, one commit).** Worker `gov-init/property-grep`. Add a single unit suite that reads the wizard module sources (`lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs` and `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`) via `Data.Text.IO.readFile` and asserts three independent properties:
   - **SC-007 / NFR-006 (no-simulation)**: zero occurrences of `buildGovernanceWithdrawalProposalCore` and `buildGovernanceWithdrawalMaterializationCore` (after Haskell-comment stripping; modelled on #159's `StakeRewardInitWizardNoSimulationSpec`).
   - **SC-008 / NFR-008 (no-key-material)**: zero occurrences of the forbidden key-material API surface — `readVaultPassphrase`, `decryptAgeVault`, `decodeWitnessVault`, `signingSourceKeyHash`, `Crypto.Age`, `Cardano.Crypto.Hash`, `Cardano.Crypto.DSIGN`, the string literals `.skey` and `.vkey`, and the bytestring-hashing helpers `blake2b224` / `blake2b256` / `Hash.blake2b`. After Haskell-comment stripping.
   - **SC-009 (no-chain-query for rewards)**: zero occurrences of `queryRewardAccountBalance`, `getRewards`, or any `*Reward*` chain-query identifier in the wizard sources. The materialization `--rewards-lovelace` is operator-typed; the wizard MUST NOT chain-query for it.

   **Unit test only** — no parallel `gate.sh` grep step (`./gate.sh` runs the suite). Three properties in one spec file keeps the slice tight and groups the "negative-space" enforcement that defines what the wizard does NOT do. RED: each property test fails the moment the wizard module mentions the forbidden symbol. GREEN: the wizard modules don't mention any, so all three properties pass; `./gate.sh` green.

   Owned files:
   `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardPropertyEnforcementSpec.hs` (new — three grep properties).

5. **Slice 5 — Documentation alignment (orchestrator-owned, single commit).** Update `README.md` and `docs/local-devnet-smoke.md` to describe `amaru-treasury-tx governance-withdrawal-init-wizard {proposal | materialization}` as the operator entry, show the two invocations with their full flag sets (including `--funding-stake-key-hash`, `--voter-key-hash`, `--anchor-hash`), include the **witness contract** (3 required key witnesses for proposal: funding payment, funding stake, voter; 1 for materialization), include the **DRep-equals-proposer caveat** (DevNet-only single-key reuse — operator IS the DRep), include the **governance-deposit shortfall reasoning** (≥ `govActionDeposit + per-cert deposits + fees`; 100k ADA mainnet, configurable DevNet), carry the explicit "unsafe inter-step carry" warning (stale funding TxIn, wrong artifact paths, observed rewards balance from before enactment, key-hash typos vs. vault identities), and forward-reference #161 (bash smoke) and #163 (resumable client state + future vault-manifest sidecar). Refresh the PR body to match. **Orchestrator-owned (per resolve-ticket): docs slices are mechanical edits the orchestrator does directly, not a tmux worker dispatch.**

   Owned files:
   `README.md`,
   `docs/local-devnet-smoke.md`,
   `specs/160-governance-withdrawal-init-wizard/tasks.md` (tick remaining `[ ]` items if any).

6. **Slice 6 — Drop `gate.sh` & ready (orchestrator-owned).**
   `chore: drop gate.sh (ready for review)`; `gh pr ready`.

## Project Structure

```text
specs/160-governance-withdrawal-init-wizard/
|-- spec.md
|-- plan.md
|-- tasks.md                  # (to be authored by speckit-tasks after this plan passes review)
`-- (no separate research.md / data-model.md / quickstart.md / contracts/ — the CLI contract
     is inlined in spec.md's Operator Path + Witness Contract sections; deferred per #159 pattern)

lib/Amaru/Treasury/
|-- Tx/
|   `-- GovernanceWithdrawalInitWizard.hs              # NEW (Answers + Env + 2 translations + Error + deposit-aware shortfall)
|-- Cli/
|   `-- GovernanceWithdrawalInitWizard.hs              # NEW (parser + 2 subcommand runners)
|-- Cli.hs                                             # +1 subcommand dispatch
`-- (no changes to IntentJSON.hs, Build.hs, Devnet/GovernanceWithdrawalInit{,/Core}.hs, Build/GovernanceWithdrawalInit.hs)

app/amaru-treasury-tx/Main.hs                          # +1 dispatch case
amaru-treasury-tx.cabal                                # +2 exposed modules
README.md                                              # operator path + witness contract + DRep caveat + deposit reasoning updated
docs/local-devnet-smoke.md                             # same
test/unit/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizardParserSpec.hs                  # NEW (Slice 1)
test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardSpec.hs                         # NEW (Slice 2; round-trip + parse errors + cross-validation + deposit-aware shortfall; extended in 3)
test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardNetworkGuardSpec.hs             # NEW (Slice 2; refined in 3)
test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardPropertyEnforcementSpec.hs      # NEW (Slice 4; 3 grep properties)
test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs                             # NEW (Slice 2; co-derived from the same source the library-core goldens use; extended in 3)
test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs               # NEW (Slice 2)
test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs        # NEW (Slice 3)
test/fixtures/governance-withdrawal-init-wizard/
    registry.json                             # shared between both sub-actions
    accounts.json                             # shared between both sub-actions
    proposal-answers.json
    proposal-intent.json
    materialization-answers.json
    materialization-intent.json
```

No changes to `lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`, or `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit{,/Core}.hs`. SC-006 enforces the `tx-build` unchanged invariant; SC-007 enforces the no-internal-simulation invariant; SC-008 enforces the no-key-material invariant; SC-009 enforces the no-chain-query-for-rewards invariant; FR-016 enforces the `SmokeSpec` unchanged invariant.

## Risks & Mitigations

- **Risk**: The resolver shape (network probe, wallet UTxO query, upper-bound-slot) duplicates code already in `RegistryInitWizard`, `WithdrawWizard`, `SwapWizard`, and `StakeRewardInitWizard`. Copy-paste drift across **five** wizard families is real.
  - **Mitigation**: Reuse the shared helpers via direct import, exactly as `StakeRewardInitWizard` does. Anything not already factored out stays a local function; defer a shared `Amaru.Treasury.Tx.WizardCommon` module to a separate refactor PR (not in scope for #160). If Slice 2 finds itself copy-pasting more than two lines from `StakeRewardInitWizard.hs`, the orchestrator pauses and decides whether to extract; default action is "import what's exported, copy what's local, don't refactor inside #160."

- **Risk**: Slice 2 is the largest in this PR — it covers resolver + proposal translation + golden + devnet guard + two artifact parses + cross-validation + deposit-aware wallet shortfall. Six orthogonal concerns in one slice exceeds #159's Slice 2 (which had five).
  - **Mitigation**: Five of the six concerns are direct adaptations of #159's Slice 2 pattern (resolver + translation + golden + devnet guard + parse-error variants); only the deposit-aware shortfall (FR-008) is genuinely new. All six are covered by unit tests at the resolver layer (no extra golden work beyond the one parity golden). The pure translation is the same shape as #159's `stakeRewardInitScriptAccountToIntent` — small, focused. If Slice 2 grows past ~500 added lines (#159's Slice 2 was ~370), the orchestrator may split it: **Slice 2a** "resolver + proposal translation + golden + network guard + cross-validation"; **Slice 2b** "deposit-aware shortfall + parse-error variants." Default plan is "ship as one slice"; tasks.md will reflect the default and call out the split-fallback explicitly.

- **Risk**: The shared `registry.json` + `accounts.json` test fixtures (Slice 2) may drift from what real `registry-init-wizard reference-scripts` + `stake-reward-init-wizard` submissions would produce in practice.
  - **Mitigation**: The two fixtures are built by `Support.GovernanceWithdrawalInitWizardFixtures` (Slice 2) from the same underlying material the existing library-core test fixtures use for governance-withdrawal-init (consult `Amaru.Treasury.Devnet.SmokeSpec` and any `Support.GovernanceWithdrawalInitFixtures` already in the codebase to find the canonical inputs). Both fixtures must round-trip through `readDevnetGovernanceWithdrawalRegistry` / `readDevnetGovernanceStakeRewardAccounts` cleanly. If a co-derivation helper is practical, use it; otherwise hand-roll JSON that the test asserts parses cleanly via the existing loaders. The cross-validator (`validateGovernanceWithdrawalPrerequisites`) is the single source of truth for treasury-scriptHash equality; both fixtures must pass it.

- **Risk**: The `--funding-seed-txin` parser shape and the new hex-validation parser shapes (`--funding-stake-key-hash` 56-hex, `--voter-key-hash` 56-hex, `--anchor-hash` 64-hex) need to be consistent and well-typed.
  - **Mitigation**: `Amaru.Treasury.LedgerParse.txInFromText :: Text -> Either String TxIn` is already used by `StakeRewardInitWizard` and earlier wizards. For the hex flags: prefer reusing any existing hex-validating reader the repo already has (grep for `eitherReader` and `parseHex` / `parseKeyHash` patterns; `Amaru.Treasury.IntentJSON.Common.parseGuardKeyHash` exists and validates the 28-byte key-hash shape — Slice 1 can wrap it in optparse-applicative's `eitherReader`). Slice 1's parser tests pin the exact behavior on both happy-path and rejection cases for each hex length.

- **Risk**: Slice 4's grep tests (no-simulation + no-key-material + no-chain-query for rewards) cover three orthogonal properties in one suite. A single property-string typo could let a regression slip through.
  - **Mitigation**: Three independent hspec `it` blocks per property; each lists its forbidden symbols verbatim and asserts zero occurrences after Haskell-comment stripping. The wizard module is small enough (Slice 2 + Slice 3 combined ≈ 600 lines) that the grep cost is negligible. The override path is: if a future legitimate import requires touching one of the forbidden symbols, the responsible PR amends the grep test in the same commit and documents the carve-out in `tasks.md`. Override is owned by an explicit follow-up ticket (likely #163's vault-manifest sidecar), not by silently breaking the test.

- **Risk**: NFR-007 (no enforced ordering between subcommands) could be silently violated by a future change that adds a sanity check like "is the proposal already enacted on chain?" before allowing materialization.
  - **Mitigation**: NFR-007 is not enforced by a grep test — it's an architectural posture. The orchestrator review at every slice checks for any chain query in the resolver other than the network probe + standard wallet query + pparams projection. If Slice 3's resolver grows to "check chain for proposal enactment," that's caught at review.

- **Risk**: NFR-008 (no key-material reads of any kind) is the hardest-to-enforce property because the forbidden-symbol list is open-ended — a future PR could introduce key handling via a symbol not on the grep list.
  - **Mitigation**: Slice 4's no-key-material grep covers the *known* key-material API surface the repo exposes today (passphrase reads, age decryption, vault decoders, hashing helpers, key-file string literals). The grep list is documented inline in the test source so future additions are visible at review. The deeper protection is human review: any future PR touching this wizard module needs an explicit reviewer check that no new key-material API has been introduced. If a legitimate need to derive a key hash from a local file emerges later (e.g. once the vault-manifest sidecar lands), that's a separate ticket that will revisit NFR-008 deliberately, not a regression.

- **Risk**: The deposit-aware shortfall (FR-008) requires the resolver to read `govActionDeposit + stakeDeposit + drepDeposit` from the pparams projection. The exact field names + Ledger types may have changed across Conway era updates.
  - **Mitigation**: Slice 2's worker is briefed to consult `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs:154-289` (which already references `stakeDeposit`, `drepDeposit`, `governanceDeposit` module-level constants) and `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs` for the canonical names. The pparams projection in `ChainContext` already carries the deposit fields needed at build time; the wizard reads from the same projection. Estimated fee is a conservative constant (mirroring what `Cardano.Tx.Build.build` uses internally) — the brief tells the worker to use a fixed-conservative overestimate rather than try to predict the exact fee, so the test stays deterministic and the operator's wallet headroom check is "≥ deposit sum + headroom".

## Complexity Tracking

No constitution violations. The principal complexity is:

1. Replicating the resolver shape from `StakeRewardInitWizard` without inviting a premature abstraction — mitigated by deferring the shared-helper extraction.
2. The shared `registry.json` + `accounts.json` test fixtures (Slice 2) need to round-trip through `readDevnetGovernanceWithdrawalRegistry` / `readDevnetGovernanceStakeRewardAccounts` cleanly AND pass the cross-validator. The mitigation above names the concrete path: co-derive from the same source the existing library-core test material uses.
3. Slice 2 has six orthogonal resolver-layer concerns (network guard, two artifact parses, cross-validation, deposit-aware shortfall, proposal translation + golden). The mitigation above names the split-fallback if the slice grows too large.
4. Slice 4's three-property grep test (no-simulation + no-key-material + no-chain-query-for-rewards) is unusual in this codebase — #158/#159 each had only the no-simulation property. The mitigation: keep the forbidden-symbol lists documented inline in the test source so future regressions are visible at review.
5. The deposit-aware shortfall (FR-008) is the only genuinely new behavior in this PR vs. the #158/#159 template — the other five slices are direct adaptations. Mitigation: deterministic fixture pparams + conservative fee overestimate keep the test scalar; the named component breakdown in the typed error makes the operator-facing surface unambiguous.
