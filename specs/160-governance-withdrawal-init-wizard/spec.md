# Feature Specification: governance-withdrawal-init-wizard

**Feature Branch**: `160-governance-withdrawal-init-wizard`
**Created**: 2026-05-18
**Last Updated**: 2026-05-19
**Status**: Draft
**GitHub Issue**: [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessors**:
- [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — flatten devnet supercommand + add init intent encodings (merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162))
- [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158) — `registry-init-wizard` (merged via PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165))
- [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159) — `stake-reward-init-wizard` (merged via PR [#168](https://github.com/lambdasistemi/amaru-treasury-tx/pull/168)) — direct architectural template for this PR
**Sibling Successor**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) — `scripts/smoke/smoke.sh`
**Deferred follow-up**: [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — client-side application state for in-progress multi-step bootstraps; promotes this stupid-baseline wizard into a resumable real wizard.

**Input**: Add `governance-withdrawal-init-wizard` to the shipped CLI with two subcommands — `proposal`, `materialization` — mirroring the two `governance-withdrawal-init` sub-action intents shipped in #157 (`GovernanceWithdrawalInitProposalInputs`, `GovernanceWithdrawalInitMaterializationInputs`). Each subcommand parses operator flags, reads the registry artifact published by #158's bootstrap and the stake/reward accounts artifact published by #159's bootstrap, performs the standard resolver work the existing wizards already do (network probe, wallet UTxO query, upper-bound-slot sampling), and writes one `SomeTreasuryIntent` JSON to `--out`. **Every value the wizard cannot derive from one of the two on-chain bootstrap artifacts is operator-typed**, including the two governance-action key hashes (`fundingStakeKeyHash`, `voterKeyHash`) and the CIP-1694 anchor content hash. The wizard touches no key material — public or private — and makes no claim about key inventory consistency. The wizard does **no** cross-step tx-body simulation. Each emitted intent feeds directly into the existing `tx-build --intent` (unchanged from #157).

> **Design framing (carried from #156 / #158 / #159):** *Explicit inter-tx unsafe.* The operator types every value that crosses a sub-step boundary the wizard cannot derive from on-chain state or from the supplied bootstrap artifacts; the wizard does no internal cross-step simulation. "Unsafe" because the operator can pick a stale funding TxIn, point `--registry` or `--stake-reward-accounts` at the wrong file, supply artifacts that were never submitted to chain, mistype a key hash so the resulting intent declares a different signer than the operator's vault will later witness, or supply a `--rewards-lovelace` that does not match the post-enactment chain balance — and the wizard cannot catch any of it. Such inconsistencies surface at `tx-build` (best case), at the `witness` step's required-signer check (typo case), or at on-chain validation (worst case). This is deliberate: ship the foundation, let operational experience surface the friction, and promote the real wizard / resumable client state in #163 later. The full design history (typed bundles, state machines, envelopes, resumability) is parked in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) with the [framing refinement](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475327010) (resumability is the load-bearing goal).
>
> **#160 ships the same posture as #158 and #159 on the operator-types-hex axis.** An earlier draft of this spec experimented with the wizard reading local `.skey` files or vault identities to derive the key hashes automatically. That experiment was rejected because (a) `.skey` files have no business being inputs to a wizard — this repo's signing model is precisely designed so private keys live in an age-encrypted vault and never sit unencrypted on disk; and (b) the existing vault format encrypts the entire identity manifest (label, key hash, source), so "vault-label lookup with no passphrase" is not achievable without a vault-format change that is out of scope for #160. The wizard therefore touches no key material. It records what the operator declares; the operator owns key-inventory consistency between the declared hash and whatever they will sign with at `witness` time. A typed-hash mismatch fails closed at the `witness` step's required-signer check; no incorrect tx reaches chain.

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

## Witness contract (what the unsigned tx will require of the operator at signing time)

The wizard's output intent feeds `tx-build`, which writes an unsigned `ConwayTx` CBOR. The required-key-witness set is implicit in that body (inputs + certificates carrying `PubKeyCert` witness kinds + the votes), as constructed by `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs:154-289`. The operator must produce one `witness` invocation per required key (Cardano validates required-key-witnesses by 28-byte key-hash equality on each witness's vkey; one physical signature satisfies every body slot that hashes to the same 28 bytes).

**For the `proposal` tx — three required key witnesses:**

| # | Operator-owned key | Body slot(s) it satisfies |
|---|---|---|
| 1 | Funding wallet **payment** key | spends `--funding-seed-txin` (one input, one collateral) |
| 2 | Funding **stake** key (= operator-typed `--funding-stake-key-hash`) | `ConwayRegDelegCert` + `DelegVote AlwaysAbstain` for funding stake credential + funding role in `proposeTreasuryWithdrawal`'s returnAccount |
| 3 | **Voter / DRep** key (= operator-typed `--voter-key-hash`) | `ConwayRegDRep drepCredential` + `ConwayRegDelegCert voterCredential (DelegVote drepKey)` — both via key-hash equality on one vkey (the library's `stakingToDRepKeyHash` and `stakingToPaymentKeyHash` are type-coercion identities, source `lib/Amaru/Treasury/IntentJSON.hs:2172-2181`); the voter base address used as the vote-output recipient also has the same hash in its payment credential slot |

**For the `materialization` tx — one required key witness:**

| # | Operator-owned key | Body slot(s) it satisfies |
|---|---|---|
| 1 | Funding wallet **payment** key | spends `--funding-seed-txin` (one input, one collateral) |

(The materialization tx also carries Plutus script witnesses for the treasury + registry scripts via the reference-script anchors taken from `--registry`; those are not key witnesses and are not the operator's concern at `witness` time.)

The wizard signs nothing, attaches nothing, submits nothing. It writes one JSON file per invocation. The downstream `witness` / `attach-witness` / `submit` pipeline carries the operator's keys (typically via the age-encrypted vault the repo already supports) into the tx envelope. The intent's two hashes (`fundingStakeKeyHash`, `voterKeyHash`) must equal the 28-byte hashes of the verification keys whose private halves the operator will sign with — that consistency is the operator's responsibility, surfaced as a typed required-signer failure at `witness` time if violated.

## DRep-equals-proposer (DevNet-only single-key reuse)

The library's `proposal` tx, by construction, submits the CIP-1694 governance proposal AND immediately self-votes "abstain" via a freshly-registered DRep, all in one transaction. The voter's stake credential, voter's payment credential, and the DRep credential are all derived from a single `--voter-key-hash` (the type-coercion helpers cited above). This is a DevNet-bootstrap design choice — in a closed DevNet there is no third-party DRep to wait for, so bundling submit-and-self-vote keeps the bootstrap self-contained.

On real Cardano (mainnet, preprod), the Conway protocol does NOT require a proposer to be a DRep: anyone can submit a proposal by bonding the deposit, and DReps vote on it as a separate registered role. The library's bundling is therefore *not* protocol-required; it is a self-contained-DevNet convenience. Mainnet/preprod stay fail-closed for governance-withdrawal until the bundling is decoupled (separate concern, separate ticket, separate spec).

For #160's wizard this means: **using `governance-withdrawal-init-wizard proposal` on DevNet means the operator IS the DRep that votes yes-by-abstaining on their own withdrawal proposal**, and controls the `--voter-key-hash` key in their vault. The spec, README, and `docs/local-devnet-smoke.md` MUST call this out explicitly so the operator is not surprised at signing time when they need to produce a witness from a "DRep key" they did not realize they had created.

## Operator path (post-#160)

Pre-requisites: the operator has already completed #158's `registry-init-wizard` chain (three subcommands → three intents → three submitted txs) and #159's `stake-reward-init-wizard` invocations (two subcommands → two intents → two submitted txs), and has `registry.json` (from #158) plus `accounts.json` (from #159) on disk. The operator also has, in their key inventory (vault and/or wherever they manage keys), the funding wallet payment key, the funding stake key, and a voter/DRep key.

```bash
# Step 1: proposal (submits the CIP-1694 governance proposal and registers the funding
# stake credential as the proposal's reward return account, AND self-votes via the
# freshly registered DRep — see "DRep-equals-proposer" above).
amaru-treasury-tx governance-withdrawal-init-wizard proposal \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --stake-reward-accounts <path/accounts.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --funding-stake-key-hash <56-hex-char-blake2b224-of-funding-stake-vkey> \
    --voter-key-hash <56-hex-char-blake2b224-of-voter-vkey> \
    --withdrawal-amount-lovelace <N> \
    --anchor-url <https://...> \
    --anchor-hash <64-hex-char-blake2b256-of-anchor-doc-bytes> \
    [--validity-hours N] [--out proposal.intent.json] [--log proposal.wizard.log]

amaru-treasury-tx tx-build --intent proposal.intent.json --out proposal.tx.cbor.hex
# Operator now runs `witness` three times, once per row of the proposal witness contract:
#   1. funding wallet payment key
#   2. funding stake key (= --funding-stake-key-hash)
#   3. voter/DRep key      (= --voter-key-hash; satisfies 3 body slots via key-hash equality)
amaru-treasury-tx witness         --vault <path/treasury.vault.age> --identity funding-payment ...
amaru-treasury-tx witness         --vault <path/treasury.vault.age> --identity funding-stake   ...
amaru-treasury-tx witness         --vault <path/treasury.vault.age> --identity voter           ...
amaru-treasury-tx attach-witness  ...
amaru-treasury-tx submit          ...

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
# Materialization tx requires exactly ONE key witness — funding wallet payment.
amaru-treasury-tx witness         --vault <path/treasury.vault.age> --identity funding-payment ...
amaru-treasury-tx attach-witness  ...
amaru-treasury-tx submit          ...
```

Operator tracks: which sub-action they need next, which wallet UTxO to use as funding seed, where `registry.json` and `accounts.json` live, the observed `--rewards-lovelace` after proposal enactment, the two 28-byte key hashes for the proposal subcommand, the 32-byte anchor content hash, the local vault identity labels for the three required signers. No safety net for funding TxIn typos, stale artifact paths, observed-rewards balance from before enactment, key-hash typos (caught at `witness` time, not at wizard time), or vault identity labels that point at the wrong keys.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Each subcommand parses flags and emits one intent file (Priority: P1)

As a release maintainer running the local DevNet bootstrap from the shipped CLI, I need `amaru-treasury-tx governance-withdrawal-init-wizard <sub-action> <flags> --out <path>` to validate the operator's flags, read the registry and stake/reward accounts artifacts, do the standard resolver work (network probe, wallet query, upper-bound-slot sampling), package the resulting intent shape, and write it to `--out` as a bare `SomeTreasuryIntent` ready for `tx-build --intent`.

**Why this priority**: This is exactly what the issue's acceptance criteria asks for — "`amaru-treasury-tx governance-withdrawal-init-wizard <flags> [--out path/intent.json]` exists. Flag set mirrors the production library function's inputs." Two subcommands give the two intent shapes #157 introduced.

**Independent Test**: For each sub-action, invoke the subcommand against a recorded chain fixture and recorded `registry.json` / `accounts.json` fixtures with a deterministic flag set; assert that the file written at `--out` (a) conforms to `intent-schema.json`, (b) decodes to a `SomeTreasuryIntent` with the matching action discriminator, (c) round-trips through `decodeTreasuryIntent` / `encodeSomeTreasuryIntent`.

**Acceptance Scenarios**:

1. **Given** a DevNet socket, a funded operator wallet, a `registry.json` from a prior successful `registry-init-wizard reference-scripts` submission, and an `accounts.json` from a prior successful `stake-reward-init-wizard` pair of submissions, **When** the operator runs `governance-withdrawal-init-wizard proposal --wallet-addr <addr> --registry <r> --stake-reward-accounts <a> --funding-seed-txin <txid>#<ix> --funding-stake-key-hash <h1> --voter-key-hash <h2> --withdrawal-amount-lovelace <N> --anchor-url <U> --anchor-hash <h3> --out proposal.json`, **Then** the wizard writes a single file at `proposal.json` containing one `SomeTreasuryIntent` with action `governance-withdrawal-init-proposal` and a `GovernanceWithdrawalInitProposalInputs` payload whose `treasuryRewardAccountHash` matches `registry.scripts.treasuryScriptHash`, whose `fundingStakeKeyHash` equals `<h1>`, whose `voterKeyHash` equals `<h2>`, whose `anchorUrl` equals `<U>`, whose `anchorHash` equals `<h3>`, and whose `withdrawalAmountLovelace` equals `<N>`.
2. **Given** the same artifact setup, **When** the operator runs `governance-withdrawal-init-wizard materialization --wallet-addr <addr> --registry <r> --stake-reward-accounts <a> --funding-seed-txin <txid>#<ix> --rewards-lovelace <N> --out materialization.json`, **Then** the wizard writes a single file at `materialization.json` containing one `SomeTreasuryIntent` with action `governance-withdrawal-init-materialization` and a `GovernanceWithdrawalInitMaterializationInputs` payload whose `treasuryRewardAccountHash`, `treasuryAddress`, `treasuryRefTxIn`, and `registryRefTxIn` all match the corresponding fields in the supplied `registry.json`, and whose `rewardsLovelace` equals `<N>`.
3. **Given** any invocation of either subcommand, **When** the wizard succeeds, **Then** the wallet block carries the operator-supplied `--funding-seed-txin` as `tiWallet.wjTxIn` and the resolved funding address as `tiWallet.wjAddress`; nothing else mutates between subcommand boundaries within #160 (each invocation is independent).

---

### User Story 2 — Each emitted intent achieves parity with the production library cores (Priority: P1)

As a maintainer of the library proof, I need each intent file the wizard emits, when fed into `tx-build --intent`, to produce an unsigned tx CBOR hex byte-identical to what the corresponding sub-transaction core (`buildGovernanceWithdrawalProposalCore`, `buildGovernanceWithdrawalMaterializationCore`) builds for the same logical inputs. This is the only thing that guarantees the wizard-driven operator path and the `SmokeSpec` library-proof path agree on what a "governance-withdrawal-init transaction" is.

**Why this priority**: Parent #156 requires that bootstrap transaction construction lives in production library code. Without parity coverage, the wizard could quietly drift from the library and yield txs that on-chain validators reject or accept off-spec.

**Independent Test**: Two goldens. For each sub-action, the wizard's resolved env + answers, run through the wizard's pure translation, plus `tx-build`, produces CBOR bytes identical to what the matching library core produces from the same logical inputs.

**Acceptance Scenarios**:

1. **Given** a fixture providing flags + resolved env + a `registry.json` + an `accounts.json` equivalent to what the library proof uses today for `governance-withdrawal-init-proposal`, **When** the `proposal` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildGovernanceWithdrawalProposalCore` produces on the same logical inputs.
2. **Given** the equivalent fixture for `governance-withdrawal-init-materialization`, **When** the `materialization` subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to what `buildGovernanceWithdrawalMaterializationCore` produces on the same logical inputs.
3. **Given** each of the two sub-action intents the wizard produced, **When** they are round-tripped through `encodeSomeTreasuryIntent` / `decodeTreasuryIntent`, **Then** the decoded value is observationally equal to the input. Two round-trip properties (same shape as #157's `GovernanceWithdrawalInitIntentSpec` round-trip).

---

### User Story 3 — Network safety preserved (Priority: P1)

As an operator with multiple network sockets configured, I need every subcommand to refuse to produce an intent for a non-DevNet network, fail-closed with a typed error before any file is written.

**Acceptance Scenarios**:

1. **Given** a wizard subcommand resolving against a non-DevNet network (chain query reports `mainnet` or `preprod` or `preview`), **When** the operator invokes either `proposal` or `materialization`, **Then** the subcommand refuses with a typed error before writing `--out`. The check happens at the resolver layer (consistent with #157's "policy at dispatcher, not decoder" rule and with #158/#159's `*WizardNetworkGuardSpec` coverage).
2. **Given** any produced intent file is later edited by hand to a non-DevNet network, **When** the operator runs `tx-build --intent` on it, **Then** `runBuildExcept` still fails closed at the dispatcher arm for the sub-action (no regression in #157's guard, confirmed at `lib/Amaru/Treasury/Build.hs:181-196`).

---

### User Story 4 — Wallet shortfall surfaces the governance deposit (Priority: P2)

As an operator running `governance-withdrawal-init-wizard proposal` for the first time, I need a wallet-shortfall error that names the governance proposal deposit explicitly — not a generic "balance too low" message — so I know I need ≥ `govActionDeposit` + the per-cert stake/DRep deposits + fees in the funding wallet before retrying.

**Why this priority**: The Conway `govActionDeposit` parameter is 100,000 ADA on mainnet (confirmed by the [Cardano Developer Portal](https://developers.cardano.org/docs/get-started/infrastructure/cardano-cli/governance/create-governance-actions/)) and configurable per-network on DevNet (typically lower for the local-bootstrap smoke). A generic "build failure" at `tx-build` time after a multi-minute wizard run is poor signal; the resolver already knows the deposit from `--registry`'s pparams projection or from the chain probe, so it can preemptively surface the requirement.

**Acceptance Scenarios**:

1. **Given** a funded wallet that does NOT have at least `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` lovelace available across pure-ADA UTxOs, **When** the operator invokes `governance-withdrawal-init-wizard proposal`, **Then** the wizard fails with a typed `GovernanceWithdrawalInitWalletShortfall` error naming each component (`govActionDeposit`, `stakeDeposit`, `drepDeposit`, estimated fee) and their sum, before any file is written.
2. **Given** the same wallet, **When** the operator invokes `governance-withdrawal-init-wizard materialization`, **Then** the shortfall check uses the materialization deposit floor (fees + min-UTxO change only; no governance deposits) and surfaces the smaller requirement.

---

### User Story 5 — Docs reflect the explicit-inter-tx-unsafe operator path with witness contract (Priority: P2)

As an operator reading `README.md` and `docs/local-devnet-smoke.md`, I need the governance-withdrawal-init flow to be documented as two independent subcommand invocations consuming the registry artifact from #158 and the accounts artifact from #159, with explicit warnings about the unsafe inter-tx boundaries (mistyped funding TxIn, stale artifact paths, key-hash typos vs. vault identities, wrong observed rewards balance) and forward references to #163 for the future resumable client state and #161 for the bash smoke. The docs MUST also include the witness contract (3 witnesses for proposal, 1 for materialization), the DRep-equals-proposer caveat, and the governance-deposit wallet-shortfall reasoning.

**Acceptance Scenarios**:

1. **Given** the merged PR, **When** an operator reads the README governance-withdrawal-init section, **Then** the worked example shows the two subcommand invocations with their flags (including `--funding-stake-key-hash`, `--voter-key-hash`, `--anchor-hash`), the witness contract table, a "common mistakes" call-out (stale funding TxIn, wrong artifact paths, observed rewards balance from before enactment, key-hash typo vs. vault identity), and a forward reference to #163.
2. **Given** the merged PR, **When** an operator reads `docs/local-devnet-smoke.md`, **Then** the governance-withdrawal-init section describes the same two-subcommand flow, names the unsafe inter-step carry explicitly (operator hand-carries the registry+accounts artifact paths, the wallet UTxO selection, the observed rewards balance, AND the consistency between declared key hashes and vault identities), documents the witness contract and DRep-equals-proposer caveat, and forward-references #161 for the bash smoke that automates the chain and #163 for the resumable client state that will subsume the manual carry.

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
- `--funding-stake-key-hash` and `--voter-key-hash` MUST each be exactly 56 hex characters; anything else fails at the parser. The wizard does NOT validate that either key hash matches any identity in the operator's vault — that consistency is the operator's responsibility, caught at `witness` time.
- `--anchor-hash` MUST be exactly 64 hex characters; anything else fails at the parser. The wizard does NOT fetch `--anchor-url` and verify its content hashes to `--anchor-hash` — that consistency is the operator's responsibility (CIP-1694 anchor content is operator-managed; an HTTP fetch at wizard time would also introduce a network dependency the wizard otherwise doesn't have).
- `--withdrawal-amount-lovelace` of zero or negative must be rejected at the parser.
- `--rewards-lovelace` of zero or negative must be rejected at the parser (materialization only).
- A subcommand invocation where the wallet has insufficient lovelace for the single tx being built must surface a typed shortfall error from the resolver (per User Story 4 for `proposal`'s governance-deposit-aware shortfall; a simpler shortfall for `materialization`), not a build failure later.
- A subcommand invocation that succeeds writes exactly one intent file. The wizard does NOT detect or warn about the operator using a stale `--funding-seed-txin` (e.g., one that has been spent by a prior tx), an `accounts.json` whose anchors are not on chain, a `--rewards-lovelace` that does not match the actual post-enactment chain balance, key hashes that do not match the vault identities the operator will use at `witness` time, or an `--anchor-url` whose content does not hash to `--anchor-hash` — *that is the "unsafe" in the design framing, by deliberate choice*. Such inconsistencies surface at `tx-build` (best case), at `witness` time as a required-signer mismatch (key-hash typo case), or at on-chain validation (worst case).
- The two subcommands are independent at the wizard layer: there is no enforced ordering between `proposal` and `materialization` from the wizard's perspective. In practice the operator MUST submit and enact the `proposal` tx before they can observe the rewards balance to feed into `materialization`; this real-world ordering is documented, not enforced.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `amaru-treasury-tx governance-withdrawal-init-wizard` exists as a top-level shipped CLI command with two subcommands: `proposal`, `materialization`. Each subcommand emits one `SomeTreasuryIntent` JSON to `--out`.
- **FR-002**: Both subcommands accept the shared wizard flag set common to other wizards where applicable: `--wallet-addr`, `--validity-hours` (optional), `--out`, optional `--log`, `--force`.
- **FR-003**: Both subcommands MUST additionally accept `--registry <path/registry.json>` (the artifact published by a prior `registry-init-wizard reference-scripts` submission), `--stake-reward-accounts <path/accounts.json>` (the artifact published by a prior `stake-reward-init-wizard` pair of submissions), and `--funding-seed-txin <txid#ix>` (the operator-chosen funding UTxO; serves as collateral).
- **FR-004**: `governance-withdrawal-init-wizard proposal` MUST additionally accept `--funding-stake-key-hash <56-hex>`, `--voter-key-hash <56-hex>`, `--withdrawal-amount-lovelace <N>`, `--anchor-url <url>`, and `--anchor-hash <64-hex>`. The wizard MUST validate the hex lengths and bake the supplied values verbatim into the `GovernanceWithdrawalInitProposalInputs` payload. The wizard MUST NOT read, validate, or interact with any key material (signing key files, verification key files, vault contents) — the two hashes are recorded as the operator declared them; the operator owns consistency between the declared hashes and the keys they will sign with at `witness` time.
- **FR-005**: `governance-withdrawal-init-wizard materialization` MUST additionally accept `--rewards-lovelace <N>` (the operator-observed treasury reward account balance after proposal enactment). The wizard MUST extract `treasuryRewardAccountHash`, `treasuryAddress`, `treasuryRefTxIn`, and `registryRefTxIn` from `--registry`'s `DevnetGovernanceWithdrawalRegistry` projection (fields `dgwrTreasuryScriptHashText`, `dgwrTreasuryAddressText`, `dgwrTreasuryRef`, `dgwrRegistryRef`). No simulation; no internal call to `buildGovernanceWithdrawalMaterializationCore`; no chain query for the rewards balance.
- **FR-006**: Both subcommands MUST parse `--stake-reward-accounts` as `DevnetGovernanceStakeRewardAccounts` and cross-validate that its `treasury.scriptHash` equals `--registry`'s `treasuryScriptHash`. Mismatch surfaces a typed cross-validation error before any chain query.
- **FR-007**: Each subcommand MUST perform the standard resolver work the existing wizards do: network probe (chain query), wallet UTxO query for the funding address resolution / shortfall check, upper-bound-slot sampling. The operator-supplied `--funding-seed-txin` populates the wallet block's `wjTxIn`.
- **FR-008**: `proposal`'s wallet-shortfall check MUST be deposit-aware: it MUST sum `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` (the per-pparams deposits read from the resolver's pparams projection) and fail with a typed `GovernanceWithdrawalInitWalletShortfall` error naming each component when the wallet's pure-ADA balance is below the total, before any file is written. `materialization`'s shortfall check MUST use a simpler `min-UTxO + estimated-fee` floor.
- **FR-009**: Each subcommand emits exactly one bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). No plan file, no bundle, no envelope, no array, no manifest. The operator manages everything between invocations (and between #159 and #160) by hand.
- **FR-010**: Each subcommand MUST fail closed at the resolver layer for non-DevNet networks before any file is written, surfacing a typed error (mirroring #158/#159's `*WizardNetworkGuardSpec`).
- **FR-011**: A new golden test suite, modelled on `test/golden/GovernanceWithdrawalInitIntentSpec.hs` (the library-proof golden #157 added) and on #159's `StakeRewardInitWizard{ScriptAccount,PlainAccount}Spec.hs`, MUST assert byte-for-byte CBOR parity between each subcommand's produced intent and the matching library core's output on the same logical inputs — two goldens total.
- **FR-012**: A round-trip property MUST cover `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for each of the two sub-action JSONs the wizard produces (two properties, same shape as #157's per-sub-action round-trip).
- **FR-013**: Fixture data MUST live under `test/fixtures/governance-withdrawal-init-wizard/` with one canonical input set per sub-action (`proposal-answers.json`, `materialization-answers.json`), a shared `registry.json` and `accounts.json` fixture, plus two golden output files (`proposal-intent.json`, `materialization-intent.json`). No signing key files, verification key files, or vault files in the fixture tree.
- **FR-014**: `README.md` and `docs/local-devnet-smoke.md` MUST describe `governance-withdrawal-init-wizard` as two independent subcommand invocations consuming `--registry registry.json` and `--stake-reward-accounts accounts.json`, carry an explicit "unsafe inter-step carry" warning (including the observed-rewards-balance carry between proposal enactment and materialization invocation, AND the operator-owned consistency between declared key hashes and signing-time vault identities), include the witness contract (3 witnesses for proposal, 1 for materialization), include the DRep-equals-proposer caveat, include the governance-deposit wallet-shortfall reasoning, and forward-reference #163 for the future resumable client state and #161 for the bash smoke.
- **FR-015**: `docs/assets/intent-schema.json` is unaffected by this PR (the two sub-action variants already shipped in #157; no schema changes here); `just schema-check` MUST stay green.
- **FR-016**: `Amaru.Treasury.Devnet.SmokeSpec` MUST remain unchanged at the library proof layer (parent #156 invariant).
- **FR-017**: The PR MUST be bisect-safe — every commit MUST pass `./gate.sh`.

### Non-Functional Requirements

- **NFR-001**: Flag conventions and naming inherit from `StakeRewardInitWizard` (`--wallet-addr`, `--registry`, `--funding-seed-txin`, `--out`, `--log`, `--force`, `--validity-hours`). New flags (`--stake-reward-accounts`, `--funding-stake-key-hash`, `--voter-key-hash`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-hash`, `--rewards-lovelace`) are local to this subcommand family.
- **NFR-002**: No new public Hackage modules; the wizard library + CLI modules are exposed via the existing `amaru-treasury-tx` cabal `library` stanza only.
- **NFR-003**: No DevNet-only code paths are introduced into shared modules other operator commands import unconditionally — the wizard's network guard lives in the wizard's own resolver, mirroring `StakeRewardInitWizard`.
- **NFR-004**: `tx-build` MUST remain single-intent and is unchanged by this PR. The Unix-pipe ergonomics from #157 are preserved.
- **NFR-005**: No bundle / plan / envelope / state-machine carrier around the intents is introduced. Each subcommand invocation writes one bare `SomeTreasuryIntent`. Carrier escalation is deliberately parked in [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
- **NFR-006**: No cross-step simulation. The wizard MUST NOT call `buildGovernanceWithdrawalProposalCore` or `buildGovernanceWithdrawalMaterializationCore` internally to derive inter-tx values. Inter-tx values come from `--registry` + `--stake-reward-accounts` (the on-chain bootstrap artifacts), `--funding-seed-txin` (operator-typed), `--rewards-lovelace` (operator-observed for materialization), and the two key hashes + anchor hash (operator-typed for proposal). (The library cores are still used by `tx-build` itself when it consumes the produced intents, and by `SmokeSpec` as library proof — they are simply not invoked from the wizard.)
- **NFR-007**: The two subcommands are independent at the wizard layer; the wizard MUST NOT enforce any required ordering between `proposal` and `materialization`. The real-world ordering (proposal must enact before materialization is meaningful) is documented, not encoded.
- **NFR-008**: The wizard MUST NOT touch key material of any kind — no signing key files (`*.skey`), no verification key files (`*.vkey`), no vault files (`*.vault.age`), no passphrase prompts, no cryptographic key derivation. The two new key hashes are operator-typed hex; the wizard validates length and pass-through encodes. Rationale: the repo's signing model is precisely designed so private keys live in the age-encrypted vault and never sit unencrypted on disk; the vault's identity manifest is encrypted alongside the signing source, so vault-label lookup without the passphrase is not achievable in the current format. Source-of-truth consistency between declared hashes and signing-time identities is the operator's responsibility, surfaced as a typed required-signer failure at `witness` time. A future resumable wizard (#163) may revisit this once a vault format supports public manifest queries; that is explicitly out of scope here.

### Key Entities

- **`GovernanceWithdrawalInitProposalAnswers`** — typed CLI answers for the `proposal` subcommand: shared wizard answer fields + `--registry` path + `--stake-reward-accounts` path + `--funding-seed-txin` + `--funding-stake-key-hash` + `--voter-key-hash` + `--withdrawal-amount-lovelace` + `--anchor-url` + `--anchor-hash`.
- **`GovernanceWithdrawalInitMaterializationAnswers`** — typed CLI answers for the `materialization` subcommand: shared wizard answer fields + `--registry` path + `--stake-reward-accounts` path + `--funding-seed-txin` + `--rewards-lovelace`.
- **`GovernanceWithdrawalInitEnv`** (or two small env types) — resolved environment per subcommand: funding wallet selection / address, network, upper-bound slot, parsed `DevnetGovernanceWithdrawalRegistry` projection, parsed `DevnetGovernanceStakeRewardAccounts` projection, pparams deposit fields (proposal only, for the deposit-aware shortfall check). No simulated values; no key material.
- **`GovernanceWithdrawalInitError`** — typed translation/resolver errors: wallet shortfall (deposit-aware for `proposal`, simple for `materialization`), malformed `--funding-seed-txin` (caught at the parser), missing/unparsable `--registry` or `--stake-reward-accounts` file, registry/accounts with wrong phase or network, registry/accounts cross-validation mismatch, key-hash length not 56 hex chars, anchor-hash length not 64 hex chars, zero-or-negative `--withdrawal-amount-lovelace` or `--rewards-lovelace`, non-DevNet network reported by chain, output-file conflict without `--force`.
- **Pure translation functions per sub-action** (`governanceWithdrawalInitProposalToIntent`, `governanceWithdrawalInitMaterializationToIntent`) — each takes its `Answers` + the resolved env (with parsed artifacts) and returns `Either GovernanceWithdrawalInitError SomeTreasuryIntent`.
- **CLI parser `governanceWithdrawalInitWizardOptsP`** — optparse-applicative parser exposing the two subcommands and their flags, modelled on `stakeRewardInitWizardOptsP`.
- **Runner `runGovernanceWithdrawalInitWizard`** — IO entry point invoked from `Main.hs`, dispatches to the sub-action runner based on the subcommand chosen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx governance-withdrawal-init-wizard --help` lists exactly two subcommands: `proposal`, `materialization`. Each subcommand's `--help` lists its required flags (parser test): both subcommands require `--registry`, `--stake-reward-accounts`, and `--funding-seed-txin`; `proposal` additionally requires `--funding-stake-key-hash`, `--voter-key-hash`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-hash`; `materialization` additionally requires `--rewards-lovelace`.
- **SC-002**: For each of the two sub-actions, a golden test asserts that the subcommand's produced intent file → `tx-build` produces CBOR bytes identical to the matching library core's output on the same logical inputs (two goldens total).
- **SC-003**: Round-trip property: `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` holds for each of the two sub-action JSONs the wizard produces (two properties total).
- **SC-004**: `nix build .#checks.unit`, `nix build .#checks.golden`, `nix build .#checks.lint`, `just schema-check`, `just format-check`, and `just hlint` are green at every commit on the branch.
- **SC-005**: `SmokeSpec` continues to build and pass against `withDevnet` using only library function calls; the SmokeSpec source tree is unchanged by this PR.
- **SC-006**: `tx-build` source is unchanged (no `--plan`, no `--step`, no array decoder). Grep across `lib/Amaru/Treasury/Cli/TxBuild.hs` and `lib/Amaru/Treasury/Build/` returns the same hits before and after this PR.
- **SC-007**: The wizard module's source contains zero references to `buildGovernanceWithdrawalProposalCore` and `buildGovernanceWithdrawalMaterializationCore` (NFR-006: no internal simulation). Grep enforces this (modelled on #159's `StakeRewardInitWizardNoSimulationSpec`).
- **SC-008**: The wizard module's source contains zero references to any key-material reading or derivation (NFR-008): no `readVaultPassphrase`, no `decryptAgeVault`, no `decodeWitnessVault`, no `signingSourceKeyHash`, no `Crypto.Age.*`, no `*.skey`/`*.vkey` file-extension string literals, no blake2b-224 / blake2b-256 calls. A grep test enforces this.
- **SC-009**: A grep test asserts the wizard module does NOT query chain for the materialization `rewardsLovelace` value (it is operator-typed). No `queryRewardAccountBalance`-shaped call in the wizard's source.
- **SC-010**: The `proposal` subcommand's wallet-shortfall test exercises the deposit-aware path (FR-008): given a wallet balance below `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` (with deterministic fixture pparams), the wizard MUST fail with `GovernanceWithdrawalInitWalletShortfall` naming each component, before any file is written.
- **SC-011**: PR body, README, and `docs/local-devnet-smoke.md` agree on the new operator path (two independent subcommand invocations consuming `--registry` + `--stake-reward-accounts` + per-subcommand flags, no atomicity / resumability), carry the explicit "unsafe" warning (including the key-hash-vs-vault consistency), include the witness contract, include the DRep-equals-proposer caveat, include the governance-deposit shortfall reasoning, and forward-reference #163.

## Command-Recovery Posture

#160 ships the **producer** of the two `governance-withdrawal-init` sub-action intents that #157 added to the `tx-build` consumer side, as two independent subcommands. The user-facing commands this PR ships are `amaru-treasury-tx governance-withdrawal-init-wizard {proposal | materialization}`; each emits one bare intent JSON; each is followed by an independent `tx-build --intent ... → witness... → witness... → witness... → attach-witness → submit` cycle for proposal (three witness invocations) and `→ witness → attach-witness → submit` for materialization (one).

In particular:

- **Operator commands (P1)**: two subcommand invocations, each emitting one intent JSON. Operator hand-carries the registry+accounts artifact paths, a wallet UTxO selection, (between proposal enactment and materialization invocation) the observed rewards balance, and the consistency between declared key hashes and vault identities. Mainnet/preprod fail closed at the wizard resolver and again at the `tx-build` dispatcher.
- **Library proof (P1)**: `Amaru.Treasury.Devnet.SmokeSpec` continues to consume the relocated library functions through `withDevnet`; unchanged here.
- **CLI proof (deferred)**: bash `smoke.sh` lives in #161.

This PR does NOT claim later child-ticket behavior:

- It does NOT introduce `scripts/smoke/smoke.sh`. That is #161.
- It does NOT change `tx-build`. It stays single-intent.
- It does NOT change `registry-init-wizard` (shipped in #158) or `stake-reward-init-wizard` (shipped in #159).
- It does NOT change mainnet or preprod semantics. The DRep-equals-proposer single-key reuse the library bakes in is a DevNet-bootstrap convenience; decoupling it for mainnet is a separate concern, separate ticket, separate spec.
- It does NOT introduce internal cross-step simulation, a typed bundle, a state-machine carrier, or any client-side state for resumability. Those concerns are parked in #163.
- It does NOT query chain for the post-enactment `rewardsLovelace` value. That stays operator-observed; the friction is intentional.
- It does NOT touch key material: no signing key reads, no verification key reads, no vault reads, no passphrase prompts, no derivations. Source-of-truth between declared key hashes and signing-time identities is the operator's responsibility (NFR-008).
- It does NOT modify the vault file format or add a vault-manifest sidecar. That is the natural prerequisite for a future "wizard reads key hashes from the same vault `witness` uses" upgrade; that prerequisite is its own ticket, not #160.

## On the deferred wizard-vs-stupid-command principle

During the #158 spec phase we established a parent-#156 invariant: *a wizard only asks the operator for genuine human decisions; system-knowable state is derived*. **#158, #159, and now #160 all deliberately override that principle and ship the stupid baseline**: the operator types every value that is not derivable from one of the supplied bootstrap artifacts. For #160 specifically the override carries an extra layer of constraint — the repo's signing model and existing vault format make automatic key-hash derivation either insecure (`.skey` reads) or out-of-scope (vault-format change). The principle remains the design goal for the resumable wizard that #163 will eventually ship, but #160 ships the deliberately-stupid baseline.

Memory notes (`feedback_wizard_vs_stupid_command`, `feedback_dont_escalate_carrier_design`, `feedback_client_state_at_build_sign_submit`, `project_bootstrap_runstate_deferred`) record both the principle and the context of the override.

## Non-Goals

- New wizard commands beyond `governance-withdrawal-init-wizard`. (`#161` for the bash smoke; no further wizards after this.)
- Bash CLI-driven smoke. (`#161`.)
- Mainnet or preprod safety for the bootstrap actions. The DRep-equals-proposer single-key reuse the library bakes in is a DevNet-bootstrap convenience; decoupling it for mainnet is its own concern.
- A bundle / plan / envelope / state-machine carrier (deferred to #163).
- Cross-step simulation; internal derivation of inter-tx state (deferred to #163's resumable wizard).
- Chain query for the post-enactment `rewardsLovelace` (deferred to #163).
- Resumability after interruption; multi-sig witness collection state (deferred to #163).
- Modifying the seven `SomeTreasuryIntent` variants from #157.
- Modifying `tx-build`, `witness`, `submit`, `vault create`, or any existing wizard's output format.
- Modifying the vault file format. The wizard taking key hashes from the same vault `witness` consumes is a natural future ergonomics layer, but it requires either a vault-manifest sidecar (a small format change) or a passphrase prompt in the wizard (rejected). Either approach is its own ticket.
- Promoting library `Devnet/*Init.hs` runners as Hackage-public modules.
- Chaining submission inside the wizard.
- Enforcing an ordering between `proposal` and `materialization` invocations (NFR-007).
- Touching key material of any form (NFR-008).

## Parent Carry-Forward Invariants

From #156, every child carries these invariants; #160 inherits them all *except* the wizard-vs-stupid-command invariant (overridden for the same reasons as #158 and #159, with the additional vault-format constraint above):

- Shipped CLI bootstrap surface produces unsigned txs only; subcommand → intent JSON → `tx-build` → unsigned CBOR; signing and submission stay on `witness` / `attach-witness` / `submit`.
- Bootstrap transaction construction lives in production library code (`lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` and the cores it pulls from `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`), not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface; today's runners remain library functions consumed by `SmokeSpec` until #161.
- Two proof layers: `SmokeSpec` (library, retained here) and `smoke.sh` (CLI, deferred to #161).
- Network safety: every CLI bootstrap entry refuses non-DevNet networks (fail-closed).

## Assumptions

- The operator's wallet, at each subcommand invocation, contains enough lovelace for the single tx being built: for `proposal` that is `govActionDeposit + stakeDeposit + drepDeposit + estimated-fee` (the resolver's deposit-aware shortfall surfaces this preemptively per FR-008); for `materialization` it is `min-UTxO + estimated-fee`.
- The operator has already completed #158's `registry-init-wizard` chain end-to-end and has a `registry.json` whose `anchors` and `scripts` fields refer to actually-submitted transactions on the same DevNet.
- The operator has already completed #159's `stake-reward-init-wizard` pair end-to-end and has an `accounts.json` whose `accounts.treasury.scriptHash` equals the `registry.json`'s `treasuryScriptHash` (the wizard cross-validates this).
- The funding seed TxIn is chosen by the operator from their wallet. The wizard does not validate that the typed TxIn exists in the wallet's current UTxO set; if it does not, `tx-build` (or on-chain validation) will fail.
- The operator-supplied `--funding-stake-key-hash` and `--voter-key-hash` are the 28-byte blake2b-224 hashes of the verification keys whose private halves the operator will sign with at `witness` time. The wizard does NOT verify this; mismatch fails closed at `witness`'s required-signer check (the witness's vkey will hash to a different 28 bytes than the body's required-signer entry, so the chain rejects the submission).
- The operator-supplied `--anchor-hash` is the 32-byte blake2b-256 hash of the document the operator publishes at `--anchor-url`. The wizard does NOT fetch the URL or verify the content; that consistency is the operator's responsibility (CIP-1694 anchor content is operator-managed).
- The operator-observed `--rewards-lovelace` value for the materialization subcommand is the actual post-enactment treasury reward account balance. The wizard does not chain-query to confirm; mismatch fails at on-chain validation.
- The chain network reported by the resolver is `devnet`; mainnet, preprod, and preview fail closed.
- The operator carries the inter-step state (artifact paths, funding TxIn selection, observed rewards balance, declared key hashes and how they map to vault identities) in their head, in shell scripts, or in a note file. The friction is intentional and informs the #163 spec phase.
- The two subcommands are independent at the wizard layer; the real-world ordering (proposal before materialization) is the operator's responsibility.
- On DevNet, the operator IS the DRep that votes on their own proposal (per "DRep-equals-proposer" above). The operator's vault must hold a key whose hash equals `--voter-key-hash`; that key is reused by the library's tx body in three role slots (voter stake, voter payment, DRep credential) via type-coercion identities, so one signature from that key satisfies all three.
