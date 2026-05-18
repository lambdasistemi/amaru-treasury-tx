# Feature Specification: governance-withdrawal-init-wizard

**Feature Branch**: `160-governance-withdrawal-init-wizard`
**Created**: 2026-05-18
**Status**: Draft
**GitHub Issue**: [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessors**:
- [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — flatten devnet supercommand + add init intent encodings (merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162))
- [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158) — `registry-init-wizard` (merged via PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165))
- [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159) — `stake-reward-init-wizard` (merged via PR [#168](https://github.com/lambdasistemi/amaru-treasury-tx/pull/168)) — direct architectural template for this PR
**Sibling Successor**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) — `scripts/smoke/smoke.sh`
**Deferred follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — client-side application state for in-progress multi-step bootstraps; promotes this stupid-baseline-with-local-derivation wizard into a resumable real wizard.

**Input**: Add `governance-withdrawal-init-wizard` to the shipped CLI with two subcommands — `proposal`, `materialization` — mirroring the two `governance-withdrawal-init` sub-action intents shipped in #157 (`GovernanceWithdrawalInitProposalInputs`, `GovernanceWithdrawalInitMaterializationInputs`). Each subcommand parses operator flags, reads the registry artifact published by #158's bootstrap and the stake/reward accounts artifact published by #159's bootstrap, performs the standard resolver work the existing wizards already do (network probe, wallet UTxO query, upper-bound-slot sampling), derives the per-action key hashes and anchor hash from operator-supplied local key/document files, and writes one `SomeTreasuryIntent` JSON to `--out`. **Inter-tx state is operator-typed**, mirroring #158/#159: the funding seed TxIn (also serving as collateral) is passed by flag; the registry-derived values (treasury reward account hash, treasury address, treasury reference-script TxIn, registry reference-script TxIn) are read from the registry artifact path the operator supplies; the cross-validation against the stake/reward accounts artifact uses the path the operator supplies. The wizard does **no** cross-step tx-body simulation. Each emitted intent feeds directly into the existing `tx-build --intent` (unchanged from #157).

> **Design framing (carried from #156 / #158 / #159):** *Explicit inter-tx unsafe.* The operator types every value that crosses a sub-step boundary the wizard cannot derive from on-chain state or from the supplied bootstrap artifacts; the wizard does no internal cross-step simulation. "Unsafe" because the operator can pick a stale funding TxIn, point `--registry` or `--stake-reward-accounts` at the wrong file, or supply artifacts that were never submitted to chain — and the wizard cannot catch any of it. This is deliberate: ship the foundation, let operational experience surface the friction, and promote the real wizard / resumable client state in #163 later. The full design history (typed bundles, state machines, envelopes, resumability) is parked in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) with the [framing refinement](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475327010) (resumability is the load-bearing goal).
>
> **#160 inherits #159's posture on inter-tx state but diverges on local derivation.** #158 and #159 had the operator type *every* hash (registry policy ids, script hashes, key hashes) as a 56-hex-char flag. #160's proposal sub-action would require the operator to manually type four 28-byte key hashes (funding stake key, voter key — used three ways per the production single-key derivation) plus a 32-byte CIP-1694 anchor content hash. That's five hex strings per invocation, none of them inter-tx state, all of them mechanically derivable from local files the operator already has on disk (the signing key files they will use to sign the eventual unsigned tx, and the anchor document they are publishing). Per the wizard-vs-stupid-command principle (memory `feedback_wizard_vs_stupid_command`), system-knowable state that is *not* inter-tx state SHOULD be derived. **#160 therefore derives these from local files and only the inter-tx state stays operator-typed.** This is the smallest deviation from #158/#159 that materially reduces the typo surface on the most key-hash-dense bootstrap step.

## Sub-action surface

`governance-withdrawal-init-wizard` has two subcommands, one per sub-action shipped in #157:

```text
governance-withdrawal-init-wizard proposal       — submits the CIP-1694 governance proposal
                                                   that requests a treasury withdrawal into
                                                   the registered treasury reward account;
                                                   registers the funding stake credential
                                                   used as the proposal's reward return
                                                   account on rejection; carries a single
                                                   voter signing key hash reused for the
                                                   voter stake credential, voter payment
                                                   credential, and DRep credential (matches
                                                   the production single-key derivation);
                                                   spends the funding seed UTxO and uses it
                                                   as collateral.
governance-withdrawal-init-wizard materialization — after the proposal has enacted on-chain
                                                   and the treasury reward account has
                                                   accrued the withdrawn lovelace, withdraws
                                                   the observed reward balance into the
                                                   treasury contract address; references the
                                                   treasury and registry reference-script
                                                   anchors from the registry artifact;
                                                   spends the funding seed UTxO and uses it
                                                   as collateral.
```

Each subcommand emits **one** bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). The two are independent invocations, but there IS a required real-world ordering between them at the chain level: materialization is only meaningful AFTER the proposal enacts and rewards accrue (encoded by the operator-typed `--rewards-lovelace` value). The wizard does NOT enforce this ordering — that is the operator's responsibility, mirroring #158/#159's posture.

## Operator path (post-#160)

Pre-requisites: the operator has already completed #158's `registry-init-wizard` chain (three subcommands → three intents → three submitted txs) and #159's `stake-reward-init-wizard` invocations (two subcommands → two intents → two submitted txs), and has `registry.json` (from #158) plus `accounts.json` (from #159) on disk.

```bash
# Step 1: proposal (submits the CIP-1694 governance proposal and registers the funding
# stake credential as the proposal's reward return account).
amaru-treasury-tx governance-withdrawal-init-wizard proposal \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --stake-reward-accounts <path/accounts.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --funding-signing-key-file <path/funding.skey> \
    --voter-signing-key-file <path/voter.skey> \
    --withdrawal-amount-lovelace <N> \
    --anchor-url <https://...> \
    --anchor-doc-file <path/anchor.json> \
    [--validity-hours N] [--out proposal.intent.json] [--log proposal.wizard.log]

amaru-treasury-tx tx-build --intent proposal.intent.json --out proposal.tx.cbor.hex
amaru-treasury-tx witness  ...
amaru-treasury-tx submit   ...

# === Operator waits for proposal to enact on chain and observes the resulting
# === treasury reward account balance (e.g., via cardano-cli query stake-address-info
# === or Ogmios). This is the inter-tx state the operator hand-carries to step 2.

# Step 2: materialization (withdraws the observed rewards into the treasury contract).
amaru-treasury-tx governance-withdrawal-init-wizard materialization \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --stake-reward-accounts <path/accounts.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --rewards-lovelace <observed-balance> \
    [--validity-hours N] [--out materialization.intent.json] [--log materialization.wizard.log]

amaru-treasury-tx tx-build --intent materialization.intent.json --out materialization.tx.cbor.hex
amaru-treasury-tx witness  ...
amaru-treasury-tx submit   ...
```

Operator tracks: which sub-action they need next, which wallet UTxO to use as funding seed, where `registry.json` and `accounts.json` live, the observed `--rewards-lovelace` after proposal enactment, the local paths to their `funding.skey` / `voter.skey` / `anchor.json` files. No safety net for funding TxIn typos, stale artifact paths, mismatched key files, or wrong observed balance.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Each subcommand parses flags and emits one intent file (Priority: P1)

As a release maintainer running the local DevNet bootstrap from the shipped CLI, I need `amaru-treasury-tx governance-withdrawal-init-wizard <sub-action> <flags> --out <path>` to validate the operator's flags, read the registry and stake/reward accounts artifacts, derive the per-action key hashes and anchor hash from the operator-supplied local files (proposal only), do the standard resolver work (network probe, wallet query, upper-bound-slot sampling), package the resulting intent shape, and write it to `--out` as a bare `SomeTreasuryIntent` ready for `tx-build --intent`.

**Why this priority**: This is exactly what the issue's acceptance criteria asks for — "`amaru-treasury-tx governance-withdrawal-init-wizard <flags> [--out path/intent.json]` exists. Flag set mirrors the production library function's inputs." Two subcommands give the two intent shapes #157 introduced.

**Independent Test**: For each sub-action, invoke the subcommand against a recorded chain fixture, recorded `registry.json` and `accounts.json` fixtures, and (for `proposal`) recorded `funding.skey` / `voter.skey` / `anchor.json` fixtures with a deterministic flag set; assert that the file written at `--out` (a) conforms to `intent-schema.json`, (b) decodes to a `SomeTreasuryIntent` with the matching action discriminator, (c) round-trips through `decodeTreasuryIntent` / `encodeSomeTreasuryIntent`.

**Acceptance Scenarios**:

1. **Given** a DevNet socket, a funded operator wallet, a `registry.json` from a prior successful `registry-init-wizard reference-scripts` submission, an `accounts.json` from a prior successful `stake-reward-init-wizard` pair of submissions, and local `funding.skey` / `voter.skey` / `anchor.json` files, **When** the operator runs `governance-withdrawal-init-wizard proposal --wallet-addr <addr> --registry <r> --stake-reward-accounts <a> --funding-seed-txin <txid>#<ix> --funding-signing-key-file <fs> --voter-signing-key-file <vs> --withdrawal-amount-lovelace <N> --anchor-url <U> --anchor-doc-file <d> --out proposal.json`, **Then** the wizard writes a single file at `proposal.json` containing one `SomeTreasuryIntent` with action `governance-withdrawal-init-proposal` and a `GovernanceWithdrawalInitProposalInputs` payload whose `treasuryRewardAccountHash` matches `registry.scripts.treasuryScriptHash`, whose `fundingStakeKeyHash` matches the 28-byte key hash derived from the supplied funding signing key, whose `voterKeyHash` matches the 28-byte key hash derived from the supplied voter signing key, whose `anchorUrl` matches the supplied flag, and whose `anchorHash` matches the 32-byte blake2b-256 hash of the supplied anchor doc file.
2. **Given** the same artifact setup, **When** the operator runs `governance-withdrawal-init-wizard materialization --wallet-addr <addr> --registry <r> --stake-reward-accounts <a> --funding-seed-txin <txid>#<ix> --rewards-lovelace <N> --out materialization.json`, **Then** the wizard writes a single file at `materialization.json` containing one `SomeTreasuryIntent` with action `governance-withdrawal-init-materialization` and a `GovernanceWithdrawalInitMaterializationInputs` payload whose `treasuryRewardAccountHash`, `treasuryAddress`, `treasuryRefTxIn`, and `registryRefTxIn` all match the corresponding fields in the supplied `registry.json`, and whose `rewardsLovelace` matches the operator-supplied flag.
3. **Given** any invocation of either subcommand, **When** the wizard succeeds, **Then** the wallet block carries the operator-supplied `--funding-seed-txin` as `tiWallet.wjTxIn` and the resolved funding address as `tiWallet.wjAddress`; nothing else mutates between subcommand boundaries within #160 (each invocation is independent).

---

### User Story 2 — Each emitted intent achieves parity with the production library cores (Priority: P1)

As a maintainer of the library proof, I need each intent file the wizard emits, when fed into `tx-build --intent`, to produce an unsigned tx CBOR hex byte-identical to what the corresponding sub-transaction core (`buildGovernanceWithdrawalProposalCore`, `buildGovernanceWithdrawalMaterializationCore`) builds for the same logical inputs. This is the only thing that guarantees the wizard-driven operator path and the `SmokeSpec` library-proof path agree on what a "governance-withdrawal-init transaction" is.

**Why this priority**: Parent #156 requires that bootstrap transaction construction lives in production library code. Without parity coverage, the wizard could quietly drift from the library and yield txs that on-chain validators reject or accept off-spec.

**Independent Test**: Two goldens. For each sub-action, the wizard's resolved env + answers, run through the wizard's pure translation, plus `tx-build`, produces CBOR bytes identical to what the matching library core produces from the same logical inputs.

**Acceptance Scenarios**:

1. **Given** a fixture providing flags + resolved env + a `registry.json` + an `accounts.json` + signing key + anchor doc equivalent to what the library proof uses today for `governance-withdrawal-init-proposal`, **When** the `proposal` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildGovernanceWithdrawalProposalCore` produces on the same logical inputs.
2. **Given** the equivalent fixture for `governance-withdrawal-init-materialization`, **When** the `materialization` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildGovernanceWithdrawalMaterializationCore` produces on the same logical inputs.
3. **Given** each of the two sub-action intents the wizard produced, **When** they are round-tripped through `encodeSomeTreasuryIntent` / `decodeTreasuryIntent`, **Then** the decoded value is observationally equal to the input. Two round-trip properties (same shape as #157's `GovernanceWithdrawalInitIntentSpec` round-trip).

---

### User Story 3 — Network safety preserved (Priority: P1)

As an operator with multiple network sockets configured, I need every subcommand to refuse to produce an intent for a non-DevNet network, fail-closed with a typed error before any file is written.

**Acceptance Scenarios**:

1. **Given** a wizard subcommand resolving against a non-DevNet network (chain query reports `mainnet` or `preprod` or `preview`), **When** the operator invokes either `proposal` or `materialization`, **Then** the subcommand refuses with a typed error before writing `--out`. The check happens at the resolver layer (consistent with #157's "policy at dispatcher, not decoder" rule and with #158/#159's `*WizardNetworkGuardSpec` coverage).
2. **Given** any produced intent file is later edited by hand to a non-DevNet network, **When** the operator runs `tx-build --intent` on it, **Then** `runBuildExcept` still fails closed at the dispatcher arm for the sub-action (no regression in #157's guard, confirmed at `lib/Amaru/Treasury/Build.hs:181-196`).

---

### User Story 4 — Docs reflect the explicit-inter-tx-unsafe operator path with local derivation (Priority: P2)

As an operator reading `README.md` and `docs/local-devnet-smoke.md`, I need the governance-withdrawal-init flow to be documented as two independent subcommand invocations consuming the registry artifact from #158 and the accounts artifact from #159, with explicit warnings about the unsafe inter-tx boundaries (mistyped funding TxIn, stale artifact paths, wrong observed rewards balance, mismatched signing key files) and a forward reference to #163 as the place where the manual carry will be superseded by a resumable state machine. The docs MUST also note the per-action key-hash and anchor-hash derivation contract so operators know which inputs are local-file-derived vs which are operator-typed.

**Acceptance Scenarios**:

1. **Given** the merged PR, **When** an operator reads the README governance-withdrawal-init section, **Then** the worked example shows the two subcommand invocations with the proposal step's `--funding-signing-key-file` / `--voter-signing-key-file` / `--anchor-doc-file` flags (local derivation), the materialization step's `--rewards-lovelace` flag (operator-observed chain state), and a "common mistakes" call-out (stale funding TxIn, wrong artifact paths, observed rewards balance from before enactment, signing key file that does not match the funding wallet) plus a forward reference to #163.
2. **Given** the merged PR, **When** an operator reads `docs/local-devnet-smoke.md`, **Then** the governance-withdrawal-init section describes the same two-subcommand flow, names the unsafe inter-step carry explicitly (operator hand-carries the registry+accounts artifact paths, the wallet UTxO selection, and the observed rewards balance between #159's bootstrap and #160's two subcommands), notes which inputs the wizard derives from local files (key hashes, anchor hash) and which it does not (rewards balance, funding TxIn), and forward-references #161 for the bash smoke that automates the chain and #163 for the resumable client state that will subsume the manual carry.

---

### Edge Cases

- A subcommand invocation with `--out` pointing at a path whose parent directory does not exist must fail with a clear error before any chain query happens — no half-resolved state on disk.
- A subcommand invocation with `--out` pointing at an existing file must refuse to overwrite without an explicit `--force` flag, surfacing a typed conflict error.
- `--funding-seed-txin` must accept the `<txid64hex>#<word16>` format and reject malformed inputs at the parser.
- A `--registry <path>` that is missing, unreadable, or unparsable as `DevnetGovernanceWithdrawalRegistry` must fail before any chain query; a typed parse error surfaces the problem to the operator.
- A `--registry` whose `phase` field is not `registry-init` or whose `network` field is not `devnet` must fail closed (the existing `readDevnetGovernanceWithdrawalRegistry` parser already enforces this; the wizard surfaces the error as a typed CLI failure).
- A `--stake-reward-accounts <path>` that is missing, unreadable, or unparsable as `DevnetGovernanceStakeRewardAccounts` must fail before any chain query; a typed parse error surfaces the problem.
- A `--stake-reward-accounts` whose `phase` field is not `stake-reward-init` or whose `network` field is not `devnet` must fail closed (the existing `readDevnetGovernanceStakeRewardAccounts` parser already enforces this; the wizard surfaces the error as a typed CLI failure).
- A `--stake-reward-accounts` whose `treasury.scriptHash` does not equal `--registry`'s `treasuryScriptHash` must fail before any chain query with a typed cross-validation error (the existing library function `validateGovernanceWithdrawalPrerequisites` enforces this; the wizard surfaces it as a typed CLI failure).
- A `--funding-signing-key-file` or `--voter-signing-key-file` that is missing, unreadable, or not a valid Ed25519 signing key must fail before any chain query with a typed parse error.
- A `--anchor-doc-file` that is missing or unreadable must fail before any chain query with a typed read error. The wizard does NOT validate the document's *content* against the supplied `--anchor-url` (CIP-1694 anchor content is operator-managed); it only hashes the bytes.
- A `--withdrawal-amount-lovelace` of zero or negative must be rejected at the parser.
- A `--rewards-lovelace` of zero or negative must be rejected at the parser (materialization only).
- A subcommand invocation where the wallet has insufficient lovelace for the single tx being built must surface a typed shortfall error from the resolver, not a build failure later.
- A subcommand invocation that succeeds writes exactly one intent file. The wizard does NOT detect or warn about the operator using a stale `--funding-seed-txin` (e.g., one that has been spent by a prior tx), an `accounts.json` whose anchors are not on chain, a `--rewards-lovelace` that does not match the actual post-enactment chain balance, or a `--voter-signing-key-file` that does not match the key the operator will use to sign the submission — *that is the "unsafe" in the design framing, by deliberate choice*. Such inconsistencies surface at `tx-build` (best case) or at on-chain validation (worst case).
- The two subcommands are independent at the wizard layer: there is no enforced ordering between `proposal` and `materialization` from the wizard's perspective. In practice the operator MUST submit and enact the `proposal` tx before they can observe the rewards balance to feed into `materialization`; this real-world ordering is documented, not enforced.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `amaru-treasury-tx governance-withdrawal-init-wizard` exists as a top-level shipped CLI command with two subcommands: `proposal`, `materialization`. Each subcommand emits one `SomeTreasuryIntent` JSON to `--out`.
- **FR-002**: Both subcommands accept the shared wizard flag set common to other wizards where applicable: `--wallet-addr`, `--validity-hours` (optional), `--out`, optional `--log`, `--force`.
- **FR-003**: Both subcommands MUST additionally accept `--registry <path/registry.json>` (the artifact published by a prior `registry-init-wizard reference-scripts` submission), `--stake-reward-accounts <path/accounts.json>` (the artifact published by a prior `stake-reward-init-wizard` pair of submissions), and `--funding-seed-txin <txid#ix>` (the operator-chosen funding UTxO; serves as collateral).
- **FR-004**: `governance-withdrawal-init-wizard proposal` MUST additionally accept `--funding-signing-key-file <path>`, `--voter-signing-key-file <path>`, `--withdrawal-amount-lovelace <N>`, `--anchor-url <url>`, and `--anchor-doc-file <path>`. The wizard MUST derive `fundingStakeKeyHash` and `voterKeyHash` as the 28-byte blake2b-224 key hashes of the corresponding Ed25519 verification keys, and `anchorHash` as the 32-byte blake2b-256 hash of the anchor doc file bytes. No simulation; no internal call to `buildGovernanceWithdrawalProposalCore`.
- **FR-005**: `governance-withdrawal-init-wizard materialization` MUST additionally accept `--rewards-lovelace <N>` (the operator-observed treasury reward account balance after proposal enactment). The wizard MUST extract `treasuryRewardAccountHash`, `treasuryAddress`, `treasuryRefTxIn`, and `registryRefTxIn` from `--registry`'s `DevnetGovernanceWithdrawalRegistry` projection (fields `dgwrTreasuryScriptHashText`, `dgwrTreasuryAddressText`, `dgwrTreasuryRef`, `dgwrRegistryRef`). No simulation; no internal call to `buildGovernanceWithdrawalMaterializationCore`; no chain query for the rewards balance.
- **FR-006**: Both subcommands MUST parse `--stake-reward-accounts` as `DevnetGovernanceStakeRewardAccounts` and cross-validate that its `treasury.scriptHash` equals `--registry`'s `treasuryScriptHash`. Mismatch surfaces a typed cross-validation error before any chain query.
- **FR-007**: Each subcommand MUST perform the standard resolver work the existing wizards do: network probe (chain query), wallet UTxO query for the funding address resolution / shortfall check, upper-bound-slot sampling. The operator-supplied `--funding-seed-txin` populates the wallet block's `wjTxIn`.
- **FR-008**: Each subcommand emits exactly one bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). No plan file, no bundle, no envelope, no array, no manifest. The operator manages everything between invocations (and between #159 and #160) by hand.
- **FR-009**: Each subcommand MUST fail closed at the resolver layer for non-DevNet networks before any file is written, surfacing a typed error (mirroring #158/#159's `*WizardNetworkGuardSpec`).
- **FR-010**: A new golden test suite, modelled on `test/golden/GovernanceWithdrawalInitIntentSpec.hs` (the library-proof golden #157 added) and on #159's `StakeRewardInitWizard{ScriptAccount,PlainAccount}Spec.hs`, MUST assert byte-for-byte CBOR parity between each subcommand's produced intent and the matching library core's output on the same logical inputs — two goldens total.
- **FR-011**: A round-trip property MUST cover `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for each of the two sub-action JSONs the wizard produces (two properties, same shape as #157's per-sub-action round-trip).
- **FR-012**: Fixture data MUST live under `test/fixtures/governance-withdrawal-init-wizard/` with one canonical input set per sub-action (`proposal-answers.json`, `materialization-answers.json`), a shared `registry.json` and `accounts.json` fixture, fixture signing key files (`funding.skey`, `voter.skey`) and an `anchor.json` fixture for the proposal subcommand, plus two golden output files (`proposal-intent.json`, `materialization-intent.json`).
- **FR-013**: `README.md` and `docs/local-devnet-smoke.md` MUST describe `governance-withdrawal-init-wizard` as two independent subcommand invocations consuming `--registry registry.json` and `--stake-reward-accounts accounts.json`, carry an explicit "unsafe inter-step carry" warning (including the observed-rewards-balance carry between proposal enactment and materialization invocation), document which proposal inputs the wizard derives from local files (key hashes, anchor hash) and which it does not, and forward-reference #163 for the future resumable client state and #161 for the bash smoke.
- **FR-014**: `docs/assets/intent-schema.json` is unaffected by this PR (the two sub-action variants already shipped in #157; no schema changes here); `just schema-check` MUST stay green.
- **FR-015**: `Amaru.Treasury.Devnet.SmokeSpec` MUST remain unchanged at the library proof layer (parent #156 invariant).
- **FR-016**: The PR MUST be bisect-safe — every commit MUST pass `./gate.sh`.

### Non-Functional Requirements

- **NFR-001**: Flag conventions and naming inherit from `StakeRewardInitWizard` (`--wallet-addr`, `--registry`, `--funding-seed-txin`, `--out`, `--log`, `--force`, `--validity-hours`). New flags (`--stake-reward-accounts`, `--funding-signing-key-file`, `--voter-signing-key-file`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-doc-file`, `--rewards-lovelace`) are local to this subcommand family.
- **NFR-002**: No new public Hackage modules; the wizard library + CLI modules are exposed via the existing `amaru-treasury-tx` cabal `library` stanza only.
- **NFR-003**: No DevNet-only code paths are introduced into shared modules other operator commands import unconditionally — the wizard's network guard lives in the wizard's own resolver, mirroring `StakeRewardInitWizard`.
- **NFR-004**: `tx-build` MUST remain single-intent and is unchanged by this PR. The Unix-pipe ergonomics from #157 are preserved.
- **NFR-005**: No bundle / plan / envelope / state-machine carrier around the intents is introduced. Each subcommand invocation writes one bare `SomeTreasuryIntent`. Carrier escalation is deliberately parked in [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
- **NFR-006**: No cross-step simulation. The wizard MUST NOT call `buildGovernanceWithdrawalProposalCore` or `buildGovernanceWithdrawalMaterializationCore` internally to derive inter-tx values. Inter-tx values come from `--registry` + `--stake-reward-accounts` (the on-chain bootstrap artifacts), `--funding-seed-txin` (operator-typed), and `--rewards-lovelace` (operator-observed for materialization). Per-action key hashes and anchor hash come from local-file derivation per FR-004 — these are *not* inter-tx state. (The library cores are still used by `tx-build` itself when it consumes the produced intents, and by `SmokeSpec` as library proof — they are simply not invoked from the wizard.)
- **NFR-007**: The two subcommands are independent at the wizard layer; the wizard MUST NOT enforce any required ordering between `proposal` and `materialization`. The real-world ordering (proposal must enact before materialization is meaningful) is documented, not encoded.
- **NFR-008**: Signing-key-file parsing MUST accept the same CLI envelope shape that the shipped `witness` / `attach-witness` commands accept (typically `cardano-cli`-style text envelope with type `PaymentSigningKeyShelley_ed25519` or `StakeSigningKeyShelley_ed25519`; exact envelope policy to be confirmed at plan time by inspecting the existing key parser the shipped CLI already exposes). Operators MUST be able to point the wizard at the same `.skey` files they will pass to `witness` for signing the resulting unsigned tx.

### Key Entities

- **`GovernanceWithdrawalInitProposalAnswers`** — typed CLI answers for the `proposal` subcommand: shared wizard answer fields + `--registry` path + `--stake-reward-accounts` path + `--funding-seed-txin` + `--funding-signing-key-file` path + `--voter-signing-key-file` path + `--withdrawal-amount-lovelace` + `--anchor-url` + `--anchor-doc-file` path.
- **`GovernanceWithdrawalInitMaterializationAnswers`** — typed CLI answers for the `materialization` subcommand: shared wizard answer fields + `--registry` path + `--stake-reward-accounts` path + `--funding-seed-txin` + `--rewards-lovelace`.
- **`GovernanceWithdrawalInitEnv`** (or two small env types) — resolved environment per subcommand: funding wallet selection / address, network, upper-bound slot, parsed `DevnetGovernanceWithdrawalRegistry` projection, parsed `DevnetGovernanceStakeRewardAccounts` projection, derived key hashes (proposal only), derived anchor hash (proposal only). No simulated values.
- **`GovernanceWithdrawalInitError`** — typed translation/resolver errors: wallet shortfall, malformed `--funding-seed-txin` (caught at the parser), missing/unparsable `--registry` or `--stake-reward-accounts` file, registry/accounts with wrong phase or network, registry/accounts cross-validation mismatch, missing/unparsable signing key file, missing/unreadable anchor doc file, zero-or-negative `--withdrawal-amount-lovelace` or `--rewards-lovelace`, non-DevNet network reported by chain, output-file conflict without `--force`.
- **Pure translation functions per sub-action** (`governanceWithdrawalInitProposalToIntent`, `governanceWithdrawalInitMaterializationToIntent`) — each takes its `Answers` + the resolved env (with parsed artifacts and derived hashes for proposal) and returns `Either GovernanceWithdrawalInitError SomeTreasuryIntent`.
- **CLI parser `governanceWithdrawalInitWizardOptsP`** — optparse-applicative parser exposing the two subcommands and their flags, modelled on `stakeRewardInitWizardOptsP`.
- **Runner `runGovernanceWithdrawalInitWizard`** — IO entry point invoked from `Main.hs`, dispatches to the sub-action runner based on the subcommand chosen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx governance-withdrawal-init-wizard --help` lists exactly two subcommands: `proposal`, `materialization`. Each subcommand's `--help` lists its required flags (parser test): both subcommands require `--registry`, `--stake-reward-accounts`, and `--funding-seed-txin`; `proposal` additionally requires `--funding-signing-key-file`, `--voter-signing-key-file`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-doc-file`; `materialization` additionally requires `--rewards-lovelace`.
- **SC-002**: For each of the two sub-actions, a golden test asserts that the subcommand's produced intent file → `tx-build` produces CBOR bytes identical to the matching library core's output on the same logical inputs (two goldens total).
- **SC-003**: Round-trip property: `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` holds for each of the two sub-action JSONs the wizard produces (two properties total).
- **SC-004**: `nix build .#checks.unit`, `nix build .#checks.golden`, `nix build .#checks.lint`, `just schema-check`, `just format-check`, and `just hlint` are green at every commit on the branch.
- **SC-005**: `SmokeSpec` continues to build and pass against `withDevnet` using only library function calls; the SmokeSpec source tree is unchanged by this PR.
- **SC-006**: `tx-build` source is unchanged (no `--plan`, no `--step`, no array decoder). Grep across `lib/Amaru/Treasury/Cli/TxBuild.hs` and `lib/Amaru/Treasury/Build/` returns the same hits before and after this PR.
- **SC-007**: The wizard module's source contains zero references to `buildGovernanceWithdrawalProposalCore` and `buildGovernanceWithdrawalMaterializationCore` (NFR-006: no internal simulation). Grep enforces this (modelled on #159's `StakeRewardInitWizardNoSimulationSpec`).
- **SC-008**: The wizard module's source contains exactly the local-file derivation calls FR-004 prescribes: a key-hash derivation for `fundingStakeKeyHash` and `voterKeyHash` from Ed25519 verification keys (delegating to the existing key-hash helper the shipped CLI already uses for `witness`), and an anchor-hash derivation as `blake2b256(file-bytes)`. A test asserts the wizard derivation results match standalone reference computations on the fixture key/anchor inputs.
- **SC-009**: A grep test asserts the wizard module does NOT query chain for the materialization `rewardsLovelace` value (it is operator-typed). No `queryRewardAccountBalance`-shaped call in the wizard's source.
- **SC-010**: PR body, README, and `docs/local-devnet-smoke.md` agree on the new operator path (two independent subcommand invocations consuming `--registry` + `--stake-reward-accounts` + per-subcommand flags, no atomicity / resumability), carry the explicit "unsafe" warning, document the local-file derivation contract, and forward-reference #163.

## Command-Recovery Posture

#160 ships the **producer** of the two `governance-withdrawal-init` sub-action intents that #157 added to the `tx-build` consumer side, as two independent subcommands. The user-facing commands this PR ships are `amaru-treasury-tx governance-withdrawal-init-wizard {proposal | materialization}`; each emits one bare intent JSON; each is followed by an independent `tx-build --intent ... → witness → submit` cycle.

In particular:

- **Operator commands (P1)**: two subcommand invocations, each emitting one intent JSON. Operator hand-carries the registry+accounts artifact paths, a wallet UTxO selection, and (between proposal enactment and materialization invocation) the observed rewards balance. Local-file derivations relieve the operator of typing four 28-byte key hashes and one 32-byte anchor hash that would otherwise be mechanical. Mainnet/preprod fail closed at the wizard resolver and again at the `tx-build` dispatcher.
- **Library proof (P1)**: `Amaru.Treasury.Devnet.SmokeSpec` continues to consume the relocated library functions through `withDevnet`; unchanged here.
- **CLI proof (deferred)**: bash `smoke.sh` lives in #161.

This PR does NOT claim later child-ticket behavior:

- It does NOT introduce `scripts/smoke/smoke.sh`. That is #161.
- It does NOT change `tx-build`. It stays single-intent.
- It does NOT change `registry-init-wizard` (shipped in #158) or `stake-reward-init-wizard` (shipped in #159).
- It does NOT change mainnet or preprod semantics.
- It does NOT introduce internal cross-step simulation, a typed bundle, a state-machine carrier, or any client-side state for resumability. Those concerns are parked in #163.
- It does NOT query chain for the post-enactment `rewardsLovelace` value. That stays operator-observed; the friction is intentional.
- It does NOT back-port the local-file derivation to `#158`/`#159`. Those siblings shipped the stupid baseline and stay as-is; #160's deviation is bounded to the most key-hash-dense sub-action.

## On the deferred wizard-vs-stupid-command principle

During the #158 spec phase we established a parent-#156 invariant: *a wizard only asks the operator for genuine human decisions; system-knowable state is derived*. **#158 and #159 deliberately overrode that principle and shipped the stupid baseline**; #160 narrows the override — inter-tx state stays operator-typed (the friction we accepted for #163 to fix later), but per-action key hashes and the CIP-1694 anchor hash, both mechanically derivable from local files, are derived. This keeps the deliberately-stupid posture on the *interesting* axis (inter-tx state) while sparing the operator a five-hex-string-typo surface that has no design value. The full principle remains the design goal for the resumable wizard that #163 will eventually ship.

Memory notes (`feedback_wizard_vs_stupid_command`, `feedback_dont_escalate_carrier_design`, `feedback_client_state_at_build_sign_submit`, `project_bootstrap_runstate_deferred`) record both the principle and the context of this scoped deviation.

## Non-Goals

- New wizard commands beyond `governance-withdrawal-init-wizard`. (`#161` for the bash smoke; no further wizards after this.)
- Bash CLI-driven smoke. (`#161`.)
- Mainnet or preprod safety for the bootstrap actions.
- A bundle / plan / envelope / state-machine carrier (deferred to #163).
- Cross-step simulation; internal derivation of inter-tx state (deferred to #163's resumable wizard).
- Chain query for the post-enactment `rewardsLovelace` (deferred to #163).
- Resumability after interruption; multi-sig witness collection state (deferred to #163).
- Back-porting local-file derivation to `#158` or `#159`. Those merged as the stupid baseline and stay as-is.
- Modifying the seven `SomeTreasuryIntent` variants from #157.
- Modifying `tx-build`, `witness`, `submit`, or any existing wizard's output format.
- Promoting library `Devnet/*Init.hs` runners as Hackage-public modules.
- Chaining submission inside the wizard.
- Enforcing an ordering between `proposal` and `materialization` invocations (NFR-007).

## Parent Carry-Forward Invariants

From #156, every child carries these invariants; #160 inherits them all *except* the wizard-vs-stupid-command invariant (narrowed override — see "On the deferred wizard-vs-stupid-command principle"):

- Shipped CLI bootstrap surface produces unsigned txs only; subcommand → intent JSON → `tx-build` → unsigned CBOR; signing and submission stay on `witness` / `attach-witness` / `submit`.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` and the cores it pulls from `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface; today's runners remain library functions consumed by `SmokeSpec` until #161.
- Two proof layers: `SmokeSpec` (library, retained here) and `smoke.sh` (CLI, deferred to #161).
- Network safety: every CLI bootstrap entry refuses non-DevNet networks (fail-closed).

## Assumptions

- The operator's wallet, at each subcommand invocation, contains at least one pure-ADA UTxO large enough to fund the single tx being built (the same UTxO is also collateral). The wizard surfaces a typed shortfall error if not.
- The operator has already completed #158's `registry-init-wizard` chain end-to-end and has a `registry.json` whose `anchors` and `scripts` fields refer to actually-submitted transactions on the same DevNet.
- The operator has already completed #159's `stake-reward-init-wizard` pair end-to-end and has an `accounts.json` whose `accounts.treasury.scriptHash` equals the `registry.json`'s `treasuryScriptHash` (the wizard cross-validates this).
- The funding seed TxIn is chosen by the operator from their wallet. The wizard does not validate that the typed TxIn exists in the wallet's current UTxO set; if it does not, `tx-build` (or on-chain validation) will fail.
- The operator supplies the *same* signing key files (`funding.skey`, `voter.skey`) to the wizard that they will later supply to `witness` for signing the unsigned tx the resulting intent feeds into. Mismatch is operator-detectable only at on-chain validation time (the wizard derives a key hash, not a signature; the eventual signature must come from the same private key).
- The operator-observed `--rewards-lovelace` value for the materialization subcommand is the actual post-enactment treasury reward account balance. The wizard does not chain-query to confirm; mismatch fails at on-chain validation.
- The CIP-1694 anchor document at `--anchor-doc-file` is the same document the operator publishes at `--anchor-url`. The wizard only hashes the bytes; content/URL coherence is operator-managed.
- The chain network reported by the resolver is `devnet`; mainnet, preprod, and preview fail closed.
- The operator carries the inter-step state (artifact paths, funding TxIn selection, observed rewards balance) in their head, in shell scripts, or in a note file. The friction is intentional and informs the #163 spec phase.
- The two subcommands are independent at the wizard layer; the real-world ordering (proposal before materialization) is the operator's responsibility.
