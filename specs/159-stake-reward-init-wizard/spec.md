# Feature Specification: stake-reward-init-wizard

**Feature Branch**: `159-stake-reward-init-wizard`
**Created**: 2026-05-18
**Status**: Draft
**GitHub Issue**: [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessors**:
- [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — flatten devnet supercommand + add init intent encodings (merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162))
- [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158) — `registry-init-wizard` (merged via PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165)) — direct architectural template for this PR
**Deferred follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — client-side application state for in-progress multi-step bootstraps; promotes this stupid-command baseline into a real wizard.

**Input**: Add `stake-reward-init-wizard` to the shipped CLI with two subcommands — `script-account`, `plain-account` — mirroring the two `stake-reward-init` sub-action intents shipped in #157 (`StakeRewardInitScriptAccountInputs`, `StakeRewardInitPlainAccountInputs`). Each subcommand parses operator flags, reads the registry artifact published by #158's bootstrap, performs the standard resolver work the existing wizards already do (wallet UTxO query, upper-bound-slot sampling, network probe), and writes one `SomeTreasuryIntent` JSON to `--out`. **Inter-tx state is operator-typed:** the funding seed TxIn (also serving as collateral for `script-account`) is passed by flag; the registry-derived values (treasury reference-script TxIn + hash, permissions stake-script hash) are read from the registry artifact path the operator supplies. The wizard does **no** cross-step tx-body simulation. Each emitted intent feeds directly into the existing `tx-build --intent` (unchanged from #157).

> **Design framing (carried from #156 / #158):** *Explicit inter-tx unsafe.* The operator types every value that crosses a sub-step boundary the wizard cannot derive from on-chain state or from the supplied registry artifact; the wizard does no internal cross-step simulation. "Unsafe" because the operator can pick a stale funding TxIn, point `--registry` at the wrong file, or supply a registry that was never submitted to chain — and the wizard cannot catch any of it. This is deliberate: ship the foundation, let operational experience surface the friction, and promote the real wizard / resumable client state in #163 later. The full design history (typed bundles, state machines, envelopes, resumability) is parked in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) with the [framing refinement](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475327010) (resumability is the load-bearing goal).
>
> **#159 differs from #158 in one structural way:** the two sub-actions are **independent** (they do not chain into each other). Neither sub-action consumes outputs of the other. Both sub-actions consume the **registry artifact** from a prior #158 bootstrap. The only operator-typed inter-tx value per invocation is the funding seed TxIn the operator chooses from their current wallet UTxO set. This is strictly simpler than #158's three-step chain, but the explicit-inter-tx-unsafe posture, the bare-intent output, the wizard-vs-stupid-command override, and the network-safety guard all carry forward unchanged.

## Sub-action surface

`stake-reward-init-wizard` has two subcommands, one per sub-action shipped in #157:

```text
stake-reward-init-wizard script-account — registers the treasury reward account
                                          via a script-witnessed ConwayRegDelegCert
                                          (DelegVote DRepAlwaysAbstain); spends the
                                          funding seed UTxO and uses it as
                                          collateral; references the treasury
                                          reference-script anchor from the registry
                                          artifact.
stake-reward-init-wizard plain-account  — registers the permissions reward account
                                          via a key-witnessed ConwayRegCert (no
                                          deposit override); spends the funding
                                          seed UTxO; no reference inputs, no
                                          collateral, no Plutus evaluator entries.
```

Each subcommand emits **one** bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). The two are independent invocations; no plan file, no bundle, no atomicity, no required ordering between them.

## Operator path (post-#159)

Pre-requisites: the operator has already completed #158's `registry-init-wizard` chain (three subcommands → three intents → three submitted txs) and has `registry.json` on disk from that bootstrap.

```bash
# Step 1: script-account (registers treasury reward account).
amaru-treasury-tx stake-reward-init-wizard script-account \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    [--validity-hours N] [--out script-account.intent.json] [--log script-account.wizard.log]

amaru-treasury-tx tx-build --intent script-account.intent.json --out script-account.tx.cbor.hex
amaru-treasury-tx witness  ...
amaru-treasury-tx submit   ...

# Step 2: plain-account (registers permissions reward account; independent of step 1).
amaru-treasury-tx stake-reward-init-wizard plain-account \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    [--validity-hours N] [--out plain-account.intent.json] [--log plain-account.wizard.log]

amaru-treasury-tx tx-build --intent plain-account.intent.json --out plain-account.tx.cbor.hex
amaru-treasury-tx witness  ...
amaru-treasury-tx submit   ...
```

Operator tracks: which sub-action they need next, which wallet UTxO to use as funding seed (the change output from a previous submission is the typical candidate), where `registry.json` lives. No safety net for funding TxIn typos or stale registry paths.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Each subcommand parses flags and emits one intent file (Priority: P1)

As a release maintainer running the local DevNet bootstrap from the shipped CLI, I need `amaru-treasury-tx stake-reward-init-wizard <sub-action> <flags> --out <path>` to validate the operator's flags, read the registry artifact, do the standard resolver work (network probe, wallet query, upper-bound-slot sampling), package the resulting intent shape, and write it to `--out` as a bare `SomeTreasuryIntent` ready for `tx-build --intent`.

**Why this priority**: This is exactly what the issue's acceptance criteria asks for — "`amaru-treasury-tx stake-reward-init-wizard <flags> [--out path/intent.json]` exists. Flag set mirrors the production library function's inputs." Two subcommands give the two intent shapes #157 introduced.

**Independent Test**: For each sub-action, invoke the subcommand against a recorded chain fixture and a recorded `registry.json` fixture with a deterministic flag set; assert that the file written at `--out` (a) conforms to `intent-schema.json`, (b) decodes to a `SomeTreasuryIntent` with the matching action discriminator, (c) round-trips through `decodeTreasuryIntent` / `encodeSomeTreasuryIntent`.

**Acceptance Scenarios**:

1. **Given** a DevNet socket, a funded operator wallet, and a `registry.json` from a prior successful `registry-init-wizard reference-scripts` submission, **When** the operator runs `stake-reward-init-wizard script-account --wallet-addr <addr> --registry <path/registry.json> --funding-seed-txin <txid>#<ix> --out script-account.json`, **Then** the wizard writes a single file at `script-account.json` containing one `SomeTreasuryIntent` with action `stake-reward-init-script-account` and a `StakeRewardInitScriptAccountInputs` payload whose `treasuryRefTxIn` and `treasuryScriptHash` match the corresponding fields in the supplied `registry.json`.
2. **Given** the same setup, **When** the operator runs `stake-reward-init-wizard plain-account --wallet-addr <addr> --registry <path/registry.json> --funding-seed-txin <txid>#<ix> --out plain-account.json`, **Then** the wizard writes a single file at `plain-account.json` containing one `SomeTreasuryIntent` with action `stake-reward-init-plain-account` and a `StakeRewardInitPlainAccountInputs` payload whose `permissionsScriptHash` matches the corresponding field in the supplied `registry.json`.
3. **Given** any invocation of either subcommand, **When** the wizard succeeds, **Then** the wallet block carries the operator-supplied `--funding-seed-txin` as `tiWallet.wjTxIn` and the resolved funding address as `tiWallet.wjAddress`; nothing else mutates between subcommand boundaries within #159 (each invocation is independent).

---

### User Story 2 — Each emitted intent achieves parity with the production library cores (Priority: P1)

As a maintainer of the library proof, I need each intent file the wizard emits, when fed into `tx-build --intent`, to produce an unsigned tx CBOR hex byte-identical to what the corresponding sub-transaction core (`buildStakeRewardScriptAccountCore`, `buildStakeRewardPlainAccountCore`) builds for the same logical inputs. This is the only thing that guarantees the wizard-driven operator path and the `SmokeSpec` library-proof path agree on what a "stake-reward-init transaction" is.

**Why this priority**: Parent #156 requires that bootstrap transaction construction lives in production library code. Without parity coverage, the wizard could quietly drift from the library and yield txs that on-chain validators reject or accept off-spec.

**Independent Test**: Two goldens. For each sub-action, the wizard's resolved env + answers, run through the wizard's pure translation, plus `tx-build`, produces CBOR bytes identical to what the matching library core produces from the same logical inputs.

**Acceptance Scenarios**:

1. **Given** a fixture providing flags + resolved env + a `registry.json` equivalent to what the library proof uses today for `stake-reward-init-script-account`, **When** the `script-account` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildStakeRewardScriptAccountCore` produces on the same logical inputs.
2. **Given** the equivalent fixture for `stake-reward-init-plain-account`, **When** the `plain-account` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildStakeRewardPlainAccountCore` produces on the same logical inputs.
3. **Given** each of the two sub-action intents the wizard produced, **When** they are round-tripped through `encodeSomeTreasuryIntent` / `decodeTreasuryIntent`, **Then** the decoded value is observationally equal to the input. Two round-trip properties (same shape as #157's `StakeRewardInitIntentSpec` round-trip).

---

### User Story 3 — Network safety preserved (Priority: P1)

As an operator with multiple network sockets configured, I need every subcommand to refuse to produce an intent for a non-DevNet network, fail-closed with a typed error before any file is written.

**Acceptance Scenarios**:

1. **Given** a wizard subcommand resolving against a non-DevNet network (chain query reports `mainnet` or `preprod` or `preview`), **When** the operator invokes either `script-account` or `plain-account`, **Then** the subcommand refuses with a typed error before writing `--out`. The check happens at the resolver layer (consistent with #157's "policy at dispatcher, not decoder" rule and with #158's `RegistryInitWizardNetworkGuardSpec` coverage).
2. **Given** any produced intent file is later edited by hand to a non-DevNet network, **When** the operator runs `tx-build --intent` on it, **Then** `runBuildExcept` still fails closed at the dispatcher arm for the sub-action (no regression in #157's guard).

---

### User Story 4 — Docs reflect the explicit-inter-tx-unsafe operator path (Priority: P2)

As an operator reading `README.md` and `docs/local-devnet-smoke.md`, I need the stake-reward-init flow to be documented as two independent subcommand invocations consuming the registry artifact from #158, with explicit warnings about the unsafe boundaries (mistyped funding TxIn, stale registry path, registry that was never submitted) and a forward reference to #163 as the place where the manual carry will be superseded by a resumable state machine.

**Acceptance Scenarios**:

1. **Given** the merged PR, **When** an operator reads the README stake-reward-init section, **Then** the worked example shows the two subcommand invocations, each consuming `--registry registry.json` and an operator-typed `--funding-seed-txin`, plus a "common mistakes" call-out (stale funding TxIn, wrong `--registry` path, registry from an unsubmitted bootstrap) and a forward reference to #163.
2. **Given** the merged PR, **When** an operator reads `docs/local-devnet-smoke.md`, **Then** the stake-reward-init section describes the same two-subcommand flow, names the unsafe inter-step carry explicitly (operator hand-carries the registry artifact path and a wallet UTxO selection between #158's bootstrap and #159's two subcommands), and forward-references #161 for the bash smoke that automates the chain and #163 for the resumable client state that will subsume the manual carry.

---

### Edge Cases

- A subcommand invocation with `--out` pointing at a path whose parent directory does not exist must fail with a clear error before any chain query happens — no half-resolved state on disk.
- A subcommand invocation with `--out` pointing at an existing file must refuse to overwrite without an explicit `--force` flag, surfacing a typed conflict error.
- `--funding-seed-txin` must accept the `<txid64hex>#<word16>` format and reject malformed inputs at the parser.
- A `--registry <path>` that is missing, unreadable, or unparsable as `DevnetStakeRewardRegistry` must fail before any chain query; a typed parse error surfaces the problem to the operator.
- A `--registry` whose `phase` field is not `registry-init` or whose `network` field is not `devnet` must fail closed (the existing `readDevnetStakeRewardRegistry` parser already enforces this; the wizard surfaces the error as a typed CLI failure rather than a parse fail).
- A subcommand invocation where the wallet has insufficient lovelace for the single tx being built must surface a typed shortfall error from the resolver, not a build failure later.
- A subcommand invocation that succeeds writes exactly one intent file. The wizard does NOT detect or warn about the operator using a stale `--funding-seed-txin` (e.g., one that has been spent by a prior tx) or a `registry.json` whose anchors are not on chain — *that is the "unsafe" in the design framing, by deliberate choice*. Such inconsistencies surface at `tx-build` (best case) or at on-chain validation (worst case).
- The two subcommands are independent: there is no required ordering between `script-account` and `plain-account` from the wizard's perspective. The operator may invoke either first; both are equally valid against the same `registry.json`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `amaru-treasury-tx stake-reward-init-wizard` exists as a top-level shipped CLI command with two subcommands: `script-account`, `plain-account`. Each subcommand emits one `SomeTreasuryIntent` JSON to `--out`.
- **FR-002**: Both subcommands accept the shared wizard flag set common to other wizards where applicable: `--wallet-addr`, `--validity-hours` (optional), `--out`, optional `--log`, `--force`.
- **FR-003**: Both subcommands MUST additionally accept `--registry <path/registry.json>` (the artifact published by a prior `registry-init-wizard reference-scripts` submission) and `--funding-seed-txin <txid#ix>` (the operator-chosen funding UTxO; serves as collateral for `script-account`).
- **FR-004**: `stake-reward-init-wizard script-account` MUST parse `--registry` as `DevnetStakeRewardRegistry`, extract `dsrrTreasuryRef` and `dsrrTreasuryScriptHash`, and bake them into the `StakeRewardInitScriptAccountInputs` payload as `treasuryRefTxIn` and `treasuryScriptHash`. No simulation; no internal call to `buildStakeRewardScriptAccountCore`.
- **FR-005**: `stake-reward-init-wizard plain-account` MUST parse `--registry` as `DevnetStakeRewardRegistry`, extract `dsrrPermissionsScriptHash`, and bake it into the `StakeRewardInitPlainAccountInputs` payload as `permissionsScriptHash`. No simulation; no internal call to `buildStakeRewardPlainAccountCore`.
- **FR-006**: Each subcommand MUST perform the standard resolver work the existing wizards do: network probe (chain query), wallet UTxO query for the funding address resolution / shortfall check, upper-bound-slot sampling. The operator-supplied `--funding-seed-txin` populates the wallet block's `wjTxIn`.
- **FR-007**: Each subcommand emits exactly one bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). No plan file, no bundle, no envelope, no array, no manifest. The operator manages everything between invocations (and between #158 and #159) by hand.
- **FR-008**: Each subcommand MUST fail closed at the resolver layer for non-DevNet networks before any file is written, surfacing a typed error (mirroring #158's `RegistryInitWizardNetworkGuardSpec`).
- **FR-009**: A new golden test suite, modelled on `test/golden/StakeRewardInitIntentSpec.hs` (the library-proof golden #157 added) and on #158's `RegistryInitWizard{SeedSplit,Mint,ReferenceScripts}Spec.hs`, MUST assert byte-for-byte CBOR parity between each subcommand's produced intent and the matching library core's output on the same logical inputs — two goldens total.
- **FR-010**: A round-trip property MUST cover `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for each of the two sub-action JSONs the wizard produces (two properties, same shape as #157's per-sub-action round-trip).
- **FR-011**: Fixture data MUST live under `test/fixtures/stake-reward-init-wizard/` with one canonical input set per sub-action (two `<sub-action>-answers.json` files plus a shared `registry.json` fixture and the resolved-env materials each test needs) and two golden output files (`<sub-action>-intent.json`).
- **FR-012**: `README.md` and `docs/local-devnet-smoke.md` MUST describe `stake-reward-init-wizard` as two independent subcommand invocations consuming `--registry registry.json` and an operator-typed `--funding-seed-txin`, carry an explicit "unsafe inter-step carry" warning, and forward-reference #163 for the future resumable client state and #161 for the bash smoke.
- **FR-013**: `docs/assets/intent-schema.json` is unaffected by this PR (the two sub-action variants already shipped in #157; no schema changes here); `just schema-check` MUST stay green.
- **FR-014**: `Amaru.Treasury.Devnet.SmokeSpec` MUST remain unchanged at the library proof layer (parent #156 invariant).
- **FR-015**: The PR MUST be bisect-safe — every commit MUST pass `./gate.sh`.

### Non-Functional Requirements

- **NFR-001**: Flag conventions and naming inherit from `RegistryInitWizard` (`--wallet-addr`, `--out`, `--log`, `--force`, `--validity-hours`). New flags (`--registry`, `--funding-seed-txin`) are local to this subcommand family.
- **NFR-002**: No new public Hackage modules; the wizard library + CLI modules are exposed via the existing `amaru-treasury-tx` cabal `library` stanza only.
- **NFR-003**: No DevNet-only code paths are introduced into shared modules other operator commands import unconditionally — the wizard's network guard lives in the wizard's own resolver, mirroring `RegistryInitWizard`.
- **NFR-004**: `tx-build` MUST remain single-intent and is unchanged by this PR. The Unix-pipe ergonomics from #157 are preserved.
- **NFR-005**: No bundle / plan / envelope / state-machine carrier around the intents is introduced. Each subcommand invocation writes one bare `SomeTreasuryIntent`. Carrier escalation is deliberately parked in [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
- **NFR-006**: No cross-step simulation. The wizard MUST NOT call `buildStakeRewardScriptAccountCore` or `buildStakeRewardPlainAccountCore` internally to derive inter-tx values. Inter-tx values come from `--registry` (the on-chain bootstrap artifact) and `--funding-seed-txin` (operator-typed). (The library cores are still used by `tx-build` itself when it consumes the produced intents, and by `SmokeSpec` as library proof — they are simply not invoked from the wizard.)
- **NFR-007**: The two subcommands are independent at the wizard layer; the wizard MUST NOT enforce any required ordering between `script-account` and `plain-account`. The operator may invoke them in either order.

### Key Entities

- **`StakeRewardInitScriptAccountAnswers`** — typed CLI answers for the `script-account` subcommand: shared wizard answer fields + `--registry` path + `--funding-seed-txin`.
- **`StakeRewardInitPlainAccountAnswers`** — typed CLI answers for the `plain-account` subcommand: shared wizard answer fields + `--registry` path + `--funding-seed-txin`.
- **`StakeRewardInitEnv`** (or two small env types) — resolved environment per subcommand: funding wallet selection / address, network, upper-bound slot, parsed `DevnetStakeRewardRegistry` projection. No simulated values.
- **`StakeRewardInitError`** — typed translation/resolver errors: wallet shortfall, malformed `--funding-seed-txin` (caught at the parser), missing/unparsable `--registry` file, registry with wrong phase or network, non-DevNet network reported by chain, output-file conflict without `--force`.
- **Pure translation functions per sub-action** (`stakeRewardInitScriptAccountToIntent`, `stakeRewardInitPlainAccountToIntent`) — each takes its `Answers` + the resolved env (with parsed registry) and returns `Either StakeRewardInitError SomeTreasuryIntent`.
- **CLI parser `stakeRewardInitWizardOptsP`** — optparse-applicative parser exposing the two subcommands and their flags, modelled on `registryInitWizardOptsP`.
- **Runner `runStakeRewardInitWizard`** — IO entry point invoked from `Main.hs`, dispatches to the sub-action runner based on the subcommand chosen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx stake-reward-init-wizard --help` lists exactly two subcommands: `script-account`, `plain-account`. Each subcommand's `--help` lists `--registry` and `--funding-seed-txin` as required flags (parser test).
- **SC-002**: For each of the two sub-actions, a golden test asserts that the subcommand's produced intent file → `tx-build` produces CBOR bytes identical to the matching library core's output on the same logical inputs (two goldens total).
- **SC-003**: Round-trip property: `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` holds for each of the two sub-action JSONs the wizard produces (two properties total).
- **SC-004**: `nix build .#checks.unit`, `nix build .#checks.golden`, `nix build .#checks.lint`, `just schema-check`, `just format-check`, and `just hlint` are green at every commit on the branch.
- **SC-005**: `SmokeSpec` continues to build and pass against `withDevnet` using only library function calls; the SmokeSpec source tree is unchanged by this PR.
- **SC-006**: `tx-build` source is unchanged (no `--plan`, no `--step`, no array decoder). Grep across `lib/Amaru/Treasury/Cli/TxBuild.hs` and `lib/Amaru/Treasury/Build/` returns the same hits before and after this PR.
- **SC-007**: The wizard module's source contains zero references to `buildStakeRewardScriptAccountCore` and `buildStakeRewardPlainAccountCore` (NFR-006: no internal simulation). Grep enforces this (modelled on #158's `RegistryInitWizardNoSimulationSpec`).
- **SC-008**: PR body, README, and `docs/local-devnet-smoke.md` agree on the new operator path (two independent subcommand invocations consuming `--registry` + `--funding-seed-txin`, no atomicity / resumability), carry the explicit "unsafe" warning, and forward-reference #163.

## Command-Recovery Posture

#159 ships the **producer** of the two `stake-reward-init` sub-action intents that #157 added to the `tx-build` consumer side, as two independent subcommands. The user-facing commands this PR ships are `amaru-treasury-tx stake-reward-init-wizard {script-account | plain-account}`; each emits one bare intent JSON; each is followed by an independent `tx-build --intent ... → witness → submit` cycle.

In particular:

- **Operator commands (P1)**: two subcommand invocations, each emitting one intent JSON. Operator hand-carries the registry artifact path and a wallet UTxO selection across the boundary from #158's bootstrap. Mainnet/preprod fail closed at the wizard resolver and again at the `tx-build` dispatcher.
- **Library proof (P1)**: `Amaru.Treasury.Devnet.SmokeSpec` continues to consume the relocated library functions through `withDevnet`; unchanged here.
- **CLI proof (deferred)**: bash `smoke.sh` lives in #161.

This PR does NOT claim later child-ticket behavior:

- It does NOT introduce `governance-withdrawal-init-wizard`. That is #160.
- It does NOT introduce `scripts/smoke/smoke.sh`. That is #161.
- It does NOT change `tx-build`. It stays single-intent.
- It does NOT change `registry-init-wizard` (shipped in #158).
- It does NOT change mainnet or preprod semantics.
- It does NOT introduce internal cross-step simulation, a typed bundle, a state-machine carrier, or any client-side state for resumability. Those concerns are parked in #163.

## On the deferred wizard-vs-stupid-command principle

During the #158 spec phase we established a parent-#156 invariant: *a wizard only asks the operator for genuine human decisions; system-knowable state is derived*. **#159 explicitly does NOT follow that principle**, mirroring #158's same deliberate override. The operator types the funding seed TxIn directly and hand-carries the `registry.json` path across the boundary from #158. The principle remains the design goal for the resumable wizard that #163 will eventually ship, but this PR ships the deliberately-stupid baseline. Memory notes (`feedback_wizard_vs_stupid_command`, `feedback_dont_escalate_carrier_design`, `feedback_client_state_at_build_sign_submit`) record both the principle and the context of this override.

## Non-Goals

- New wizard commands beyond `stake-reward-init-wizard`. (`#160`.)
- Bash CLI-driven smoke. (`#161`.)
- Mainnet or preprod safety for the bootstrap actions.
- A bundle / plan / envelope / state-machine carrier (deferred to #163).
- Cross-step simulation; internal derivation of inter-tx state (deferred to #163's resumable wizard).
- Resumability after interruption; multi-sig witness collection state (deferred to #163).
- Modifying the seven `SomeTreasuryIntent` variants from #157.
- Modifying `tx-build`, `witness`, `submit`, or any existing wizard's output format.
- Promoting library `Devnet/*Init.hs` runners as Hackage-public modules.
- Chaining submission inside the wizard.
- Enforcing an ordering between `script-account` and `plain-account` invocations (NFR-007).

## Parent Carry-Forward Invariants

From #156, every child carries these invariants; #159 inherits them all *except* the wizard-vs-stupid-command invariant (deferred to #163 — see "On the deferred wizard-vs-stupid-command principle"):

- Shipped CLI bootstrap surface produces unsigned txs only; subcommand → intent JSON → `tx-build` → unsigned CBOR; signing and submission stay on `witness` / `attach-witness` / `submit`.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/StakeRewardInit.hs` and the cores it pulls from `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface; today's runners remain library functions consumed by `SmokeSpec` until #161.
- Two proof layers: `SmokeSpec` (library, retained here) and `smoke.sh` (CLI, deferred to #161).
- Network safety: every CLI bootstrap entry refuses non-DevNet networks (fail-closed).

## Assumptions

- The operator's wallet, at each subcommand invocation, contains at least one pure-ADA UTxO large enough to fund the single tx being built (for `script-account`, the same UTxO is also collateral). The wizard surfaces a typed shortfall error if not. (Multi-step fund planning is the operator's job; the wizard does no look-ahead.)
- The operator has already completed #158's `registry-init-wizard` chain end-to-end and has a `registry.json` whose `anchors` and `scripts` fields refer to actually-submitted transactions on the same DevNet. The wizard does not cross-check the registry contents against chain state beyond what `readDevnetStakeRewardRegistry`'s phase/network gates already enforce.
- The funding seed TxIn is chosen by the operator from their wallet (the change output of a recent submission is the typical candidate). The wizard does not validate that the typed TxIn exists in the wallet's current UTxO set; if it does not, `tx-build` (or on-chain validation) will fail.
- The chain network reported by the resolver is `devnet`; mainnet, preprod, and preview fail closed.
- The operator carries the inter-step state (registry path, funding TxIn selection) in their head, in shell scripts, or in a note file. The friction is intentional and informs the #163 spec phase.
- The two subcommands are independent; the operator may invoke either first. In practice the operator will run both during a single bootstrap session; #161's bash smoke automates the chain.
