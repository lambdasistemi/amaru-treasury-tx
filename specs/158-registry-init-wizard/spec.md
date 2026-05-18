# Feature Specification: registry-init-wizard

**Feature Branch**: `158-registry-init-wizard`
**Created**: 2026-05-17 (rewritten 2026-05-18: explicit-inter-tx-unsafe design)
**Status**: Draft
**GitHub Issue**: [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Sibling Predecessor**: [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157) — flatten devnet supercommand & add init intent encodings (merged via PR [#162](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162))
**Deferred follow-up:** [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) — client-side application state for in-progress multi-step bootstraps (resumability after interruption); promotes this baseline command into a real wizard.

**Input**: Add `registry-init-wizard` to the shipped CLI with three subcommands — `seed-split`, `mint`, `reference-scripts` — mirroring the three `registry-init` sub-action intents shipped in #157. Each subcommand parses operator flags, performs the standard resolver work the existing wizards already do (`verifyRegistry`, wallet UTxO query, upper-bound-slot sampling), and writes one `SomeTreasuryIntent` JSON to `--out`. **Inter-tx state is operator-typed**, not derived: for `mint` and `reference-scripts`, the operator hand-carries the seed TxIns produced by the previous sub-step's submission and the scope owner's key hash. The wizard does **no** cross-step tx-body simulation. Each emitted intent feeds directly into the existing `tx-build --intent` (unchanged from #157).

> **Design framing (2026-05-18, repo owner):** *Explicit inter-tx unsafe.* The operator types every value that crosses a sub-step boundary; the wizard does not derive or carry inter-tx state. "Unsafe" because the operator can mistype a seed TxIn, swap the `#0`/`#1` ordering, or paste the wrong key hash — and the wizard cannot catch any of it. This is deliberate: the goal is to ship the foundation, let operational experience surface the friction, and promote the real wizard / resumable client state in #163 later.
>
> **Background — what the prior brainstorm reached and rejected for #158:** Earlier spec drafts escalated through several designs (`--out-dir` with three derived files → JSONL plan → JSON array → keyed bundle → typed bundle with state machine + cardano-cli TextEnvelope reuse + per-entry state progression). Each step had a real motivation; the chain converged on a *client-side application state machine for resumable build/sign/submit pipelines*. That whole design space is parked in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) along with the [framing refinement](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475327010) (resumability is the load-bearing goal). **#158 ships the dumbest possible thing** that satisfies the issue's literal acceptance criteria: flag set mirrors the production library function's inputs; operator manages everything in between by hand.

## Sub-action surface

`registry-init-wizard` has three subcommands, one per sub-action shipped in #157:

```text
registry-init-wizard seed-split        — first step, no inter-tx state
registry-init-wizard mint              — takes operator-typed seed TxIns + owner key hash
registry-init-wizard reference-scripts — takes operator-typed seed TxIns + funding seed
```

Each subcommand emits **one** bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). The three are independent invocations; no plan file, no bundle, no atomicity.

## Operator path (post-#158)

```bash
# Step 1: seed-split (no inter-tx inputs).
amaru-treasury-tx registry-init-wizard seed-split \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> [--validity-hours N] [optional rationale flags] \
    --out seed-split.intent.json [--log seed-split.wizard.log]

amaru-treasury-tx tx-build --intent seed-split.intent.json --out seed-split.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# Operator records seed-split's submitted txid.

# Step 2: mint (operator hand-carries seed TxIns and owner key hash).
amaru-treasury-tx registry-init-wizard mint \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> [--validity-hours N] [optional rationale flags] \
    --scopes-seed-txin   <seed-split-txid>#0 \
    --registry-seed-txin <seed-split-txid>#1 \
    --owner-key-hash     <hex28> \
    --out mint.intent.json

amaru-treasury-tx tx-build --intent mint.intent.json --out mint.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# Operator records mint's submitted txid (to know where the change went,
# for the next step's --funding-seed-txin).

# Step 3: reference-scripts (operator hand-carries seed TxIns again + funding seed).
amaru-treasury-tx registry-init-wizard reference-scripts \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> [--validity-hours N] [optional rationale flags] \
    --scopes-seed-txin   <seed-split-txid>#0 \
    --registry-seed-txin <seed-split-txid>#1 \
    --funding-seed-txin  <some-wallet-utxo>#N \
    --out reference-scripts.intent.json

amaru-treasury-tx tx-build --intent reference-scripts.intent.json --out reference-scripts.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
```

Operator tracks: which sub-step they're on, which TxIns each previous step produced, which UTxO to use as funding seed for `reference-scripts`. No safety net.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Each subcommand parses flags and emits one intent file (Priority: P1)

As a release maintainer running the local DevNet bootstrap from the shipped CLI, I need `amaru-treasury-tx registry-init-wizard <sub-action> <flags> --out <path>` to validate the operator's flags, do the standard resolver work (verify the registry, query the wallet, sample the upper-bound slot), package the resulting intent shape, and write it to `--out` as a bare `SomeTreasuryIntent` ready for `tx-build --intent`.

**Why this priority**: This is exactly what the issue's acceptance criteria asks for — "`amaru-treasury-tx registry-init-wizard <flags> [--out path/intent.json]` exists. Flag set mirrors the inputs the production `registry-init` library function needs." Three subcommands give the three intent shapes #157 introduced.

**Independent Test**: For each sub-action, invoke the subcommand against a recorded chain fixture with a deterministic flag set; assert that the file written at `--out` (a) conforms to `intent-schema.json`, (b) decodes to a `SomeTreasuryIntent` with the matching action discriminator, (c) round-trips through `decodeTreasuryIntent` / `encodeSomeTreasuryIntent`.

**Acceptance Scenarios**:

1. **Given** a DevNet socket, a funded operator wallet, a verified registry, and a scope id, **When** the operator runs `registry-init-wizard seed-split --wallet-addr <addr> --metadata <metadata.json> --scope <id> --out seed-split.json`, **Then** the wizard writes a single file at `seed-split.json` containing one `SomeTreasuryIntent` with action `registry-init-seed-split` and the empty `RegistryInitSeedSplitInputs` payload.
2. **Given** the operator-typed seed TxIns and owner key hash from a prior `seed-split` submission, **When** the operator runs `registry-init-wizard mint --wallet-addr <addr> --metadata <metadata.json> --scope <id> --scopes-seed-txin <txid#0> --registry-seed-txin <txid#1> --owner-key-hash <hex28> --out mint.json`, **Then** the wizard writes a single file at `mint.json` containing one `SomeTreasuryIntent` with action `registry-init-mint` whose payload carries the operator-supplied values verbatim plus the wizard-resolved funding address, network, and upper-bound slot.
3. **Given** the operator-typed seed TxIns and a chosen funding-seed UTxO, **When** the operator runs `registry-init-wizard reference-scripts --wallet-addr <addr> --metadata <metadata.json> --scope <id> --scopes-seed-txin <txid#0> --registry-seed-txin <txid#1> --funding-seed-txin <utxo#n> --out reference-scripts.json`, **Then** the wizard writes a single file at `reference-scripts.json` containing one `SomeTreasuryIntent` with action `registry-init-reference-scripts` and the matching payload.

---

### User Story 2 — Each emitted intent achieves parity with the production library cores (Priority: P1)

As a maintainer of the library proof, I need each intent file the wizard emits, when fed into `tx-build --intent`, to produce an unsigned tx CBOR hex byte-identical to what the corresponding sub-transaction core (`buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore`) builds for the same logical inputs. This is the only thing that guarantees the wizard-driven operator path and the `SmokeSpec` library-proof path agree on what an "init transaction" is.

**Why this priority**: Parent #156 requires that bootstrap transaction construction lives in production library code. Without parity coverage, the wizard could quietly drift from the library and yield txs that on-chain validators reject.

**Independent Test**: Three goldens. For each sub-action, the wizard's resolved env + answers, run through the wizard's pure translation, plus `tx-build`, produces CBOR bytes identical to what the matching library core produces from the same logical inputs.

**Acceptance Scenarios**:

1. **Given** a fixture providing flags + resolved env equivalent to the `RegistryInitFixture` data already used by `RegistryInitIntentSpec`, **When** the matching subcommand is invoked, **Then** the produced intent file, when consumed by `tx-build`, yields CBOR bytes identical to the matching library core's output on the same inputs. Three goldens (one per sub-action).
2. **Given** each of the three sub-action intents the wizard produced, **When** they are round-tripped through `encodeSomeTreasuryIntent` / `decodeTreasuryIntent`, **Then** the decoded value is observationally equal to the input. Three round-trip properties (same shape as #157's `RegistryInitIntentSpec` round-trip).

---

### User Story 3 — Network safety preserved (Priority: P1)

As an operator with multiple network sockets configured, I need every subcommand to refuse to produce an intent for a non-DevNet network, fail-closed with a typed error before any file is written.

**Acceptance Scenarios**:

1. **Given** a wizard subcommand resolving against a non-DevNet network (chain query reports `mainnet` or `preprod`), **When** the operator invokes any of `seed-split` / `mint` / `reference-scripts`, **Then** the subcommand refuses with a typed error before writing `--out`. The check happens at the resolver layer (consistent with #157's "policy at dispatcher, not decoder" rule).
2. **Given** any produced intent file is later edited by hand to a non-DevNet network, **When** the operator runs `tx-build --intent` on it, **Then** `runBuildExcept` still fails closed at the dispatcher arm for the sub-action (no regression in #157's guard).

---

### User Story 4 — Docs reflect the explicit-inter-tx-unsafe operator path (Priority: P2)

As an operator reading `README.md` and `docs/local-devnet-smoke.md`, I need the registry-init flow to be documented as three independent subcommand invocations, with the operator hand-carrying seed TxIns and owner key hash between them, and with **explicit warnings** about the unsafe boundaries (mis-typed TxIns produce invalid intents that fail at `tx-build` or worse at on-chain validation). The docs must forward-reference #163 as the place where this manual carry will be superseded by a resumable state machine.

**Acceptance Scenarios**:

1. **Given** the merged PR, **When** an operator reads the README registry-init section, **Then** the worked example shows the three subcommand invocations in order, with operator-typed seed TxIns visible at the `mint` and `reference-scripts` steps, plus a "common mistakes" call-out (swapping `#0` and `#1`, using a stale txid, mismatched owner key hash) and a forward reference to #163.
2. **Given** the merged PR, **When** an operator reads `docs/local-devnet-smoke.md`, **Then** the registry-init section describes the same three-subcommand flow, names the unsafe inter-step carry explicitly, and forward-references #161 for the bash smoke that automates the chain and #163 for the resumable client state that will subsume the manual carry.

---

### Edge Cases

- A subcommand invocation with `--out` pointing at a path whose parent directory does not exist must fail with a clear error before any chain query happens — no half-resolved state on disk.
- A subcommand invocation with `--out` pointing at an existing file must refuse to overwrite without an explicit `--force` flag, surfacing a typed conflict error.
- `mint`'s `--owner-key-hash` flag must reject any string that is not exactly 56 hex characters (28-byte key hash); failure happens at the CLI parser.
- `--scopes-seed-txin`, `--registry-seed-txin`, `--funding-seed-txin` must accept the `<txid64hex>#<word16>` format and reject malformed inputs at the parser.
- A subcommand invocation where the wallet has insufficient lovelace for the (single) tx being built must surface a typed shortfall error from the resolver, not a build failure later.
- A `--metadata <metadata.json>` file that is missing or unparsable must fail before any chain query; `verifyRegistry` continues to cross-check every consumed field against chain anchors.
- A subcommand invocation that succeeds writes exactly one intent file. The wizard does NOT detect or warn about the operator typing values that are inconsistent with a previous step's outputs — *that is the "unsafe" in the design framing, by deliberate choice*. Such inconsistencies surface at `tx-build` (best case) or at on-chain validation (worst case).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `amaru-treasury-tx registry-init-wizard` exists as a top-level shipped CLI command with three subcommands: `seed-split`, `mint`, `reference-scripts`. Each subcommand emits one `SomeTreasuryIntent` JSON to `--out`.
- **FR-002**: All three subcommands accept the operator-decision flag set shared with `WithdrawWizard` where applicable: `--wallet-addr`, `--metadata`, `--scope`, `--validity-hours` (optional), `--description`, `--justification`, `--destination-label`, `--event`, `--label` (optional rationale), `--out`, optional `--log`, `--force`.
- **FR-003**: `registry-init-wizard mint` MUST additionally accept three operator-typed flags: `--scopes-seed-txin <txid#ix>`, `--registry-seed-txin <txid#ix>`, `--owner-key-hash <hex28>`. The values are baked verbatim into the `RegistryInitMintInputs` payload.
- **FR-004**: `registry-init-wizard reference-scripts` MUST additionally accept three operator-typed flags: `--scopes-seed-txin <txid#ix>`, `--registry-seed-txin <txid#ix>`, `--funding-seed-txin <txid#ix>`. The values are baked verbatim into the `RegistryInitReferenceScriptsInputs` payload (with `--funding-seed-txin` selecting the funding UTxO to spend).
- **FR-005**: Each subcommand MUST perform the standard resolver work the existing wizards do: `verifyRegistry` against the chain, wallet UTxO query for the funding address resolution / shortfall check, upper-bound-slot sampling. No cross-step tx-body simulation; no internal derivation of inter-tx values.
- **FR-006**: Each subcommand emits exactly one bare `SomeTreasuryIntent` JSON (the same shape `tx-build --intent` consumes today). No plan file, no bundle, no envelope, no array, no manifest. The operator manages everything between invocations by hand.
- **FR-007**: Each subcommand MUST fail closed at the resolver layer for non-DevNet networks before any file is written, surfacing a typed error.
- **FR-008**: A new golden test suite, modelled on `test/golden/RegistryInitIntentSpec.hs`, MUST assert byte-for-byte CBOR parity between each subcommand's produced intent and the matching library core's output on the same logical inputs — three goldens total.
- **FR-009**: A round-trip property MUST cover `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for each of the three sub-action JSONs the wizard produces (three properties, same shape as #157's per-sub-action round-trip).
- **FR-010**: Fixture data MUST live under `test/fixtures/registry-init-wizard/` with one canonical input set per sub-action (three `<sub-action>-answers.json` files plus the resolved-env materials each test needs) and three golden output files (`<sub-action>-intent.json`).
- **FR-011**: `README.md` and `docs/local-devnet-smoke.md` MUST describe `registry-init-wizard` as three independent subcommand invocations, show operator-typed seed TxIns and owner key hash at the `mint` and `reference-scripts` invocations, carry an explicit "unsafe inter-step carry" warning, and forward-reference #163 for the future resumable client state and #161 for the bash smoke.
- **FR-012**: `docs/assets/intent-schema.json` is unaffected by this PR (the three sub-action variants already shipped in #157; no schema changes here); `just schema-check` MUST stay green.
- **FR-013**: `Amaru.Treasury.Devnet.SmokeSpec` MUST remain unchanged at the library proof layer (parent #156 invariant).
- **FR-014**: The PR MUST be bisect-safe — every commit MUST pass `./gate.sh`.

### Non-Functional Requirements

- **NFR-001**: Flag conventions and naming inherit from `WithdrawWizard` where applicable; new flags (`--scopes-seed-txin`, `--registry-seed-txin`, `--owner-key-hash`, `--funding-seed-txin`) are local to this subcommand.
- **NFR-002**: No new public Hackage modules; the wizard library + trace + CLI modules are exposed via the existing `amaru-treasury-tx` cabal `library` stanza only.
- **NFR-003**: No DevNet-only code paths are introduced into shared modules other operator commands import unconditionally — the wizard's network guard lives in the wizard's own resolver, mirroring `WithdrawWizard`.
- **NFR-004**: `tx-build` MUST remain single-intent and is unchanged by this PR. The Unix-pipe ergonomics from #157 are preserved.
- **NFR-005**: No bundle / plan / envelope / state-machine carrier around the intents is introduced. Each subcommand invocation writes one bare `SomeTreasuryIntent`. Carrier escalation is deliberately parked in [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
- **NFR-006**: No cross-step simulation. The wizard MUST NOT call `buildSeedSplitCore`, `buildRegistryNftsCore`, or `buildReferenceScriptsCore` internally to derive inter-tx values. Inter-tx values come from operator-typed flags. (The library cores are still used by `tx-build` itself when it consumes the produced intents, and by `SmokeSpec` as library proof — they are simply not invoked from the wizard.)

### Key Entities

- **`RegistryInitSeedSplitAnswers`** — typed CLI answers for the `seed-split` subcommand: scope, optional validity window, optional rationale fields. No inter-tx inputs.
- **`RegistryInitMintAnswers`** — typed CLI answers for the `mint` subcommand: shared answer fields + `--scopes-seed-txin`, `--registry-seed-txin`, `--owner-key-hash`.
- **`RegistryInitReferenceScriptsAnswers`** — typed CLI answers for the `reference-scripts` subcommand: shared answer fields + `--scopes-seed-txin`, `--registry-seed-txin`, `--funding-seed-txin`.
- **`RegistryInitEnv`** (or three small env types) — resolved environment per subcommand: funding wallet selection / address, scope view, registry view, network, upper-bound slot. No simulated values.
- **`RegistryInitError`** — typed translation/resolver errors: wallet shortfall, malformed TxIn (caught at the parser), malformed owner key hash (caught at the parser), non-DevNet network, missing scope, output-file conflict without `--force`.
- **Pure translation functions per sub-action** (`registryInitSeedSplitToIntent`, `registryInitMintToIntent`, `registryInitReferenceScriptsToIntent`) — each takes its `Answers` + the resolved env and returns `Either RegistryInitError SomeTreasuryIntent`.
- **CLI parser `registryInitWizardOptsP`** — optparse-applicative parser exposing the three subcommands and their flags.
- **Runner `runRegistryInitWizard`** — IO entry point invoked from `Main.hs`, dispatches to the sub-action runner based on the subcommand chosen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx registry-init-wizard --help` lists exactly three subcommands: `seed-split`, `mint`, `reference-scripts`. `registry-init-wizard mint --help` lists the three operator-typed inter-tx flags as required (parser test).
- **SC-002**: For each of the three sub-actions, a golden test asserts that the subcommand's produced intent file → `tx-build` produces CBOR bytes identical to the matching library core's output on the same logical inputs (three goldens total).
- **SC-003**: Round-trip property: `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` holds for each of the three sub-action JSONs the wizard produces (three properties total).
- **SC-004**: `nix build .#checks.unit`, `nix build .#checks.golden`, `nix build .#checks.lint`, `just schema-check`, `just format-check`, and `just hlint` are green at every commit on the branch.
- **SC-005**: `SmokeSpec` continues to build and pass against `withDevnet` using only library function calls; the SmokeSpec source tree is unchanged by this PR.
- **SC-006**: `tx-build` source is unchanged (no `--plan`, no `--step`, no array decoder). Grep across `lib/Amaru/Treasury/Cli/TxBuild.hs` and `lib/Amaru/Treasury/Build/` returns the same hits before and after this PR.
- **SC-007**: The wizard module's source contains zero references to `buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore` (NFR-006: no internal simulation). Grep enforces this.
- **SC-008**: PR body, README, and `docs/local-devnet-smoke.md` agree on the new operator path (three independent subcommand invocations, operator-typed inter-tx state, no atomicity / resumability), carry the explicit "unsafe" warning, and forward-reference #163.

## Command-Recovery Posture

#158 ships the **producer** of the three `registry-init` sub-action intents that #157 added to the `tx-build` consumer side, as three independent subcommands. The user-facing commands this PR ships are `amaru-treasury-tx registry-init-wizard {seed-split | mint | reference-scripts}`; each emits one bare intent JSON; each is followed by an independent `tx-build --intent ... → witness → submit` cycle.

In particular:

- **Operator commands (P1)**: three subcommand invocations, each emitting one intent JSON. Operator types inter-tx state between invocations. Mainnet/preprod fail closed at the wizard resolver and again at the `tx-build` dispatcher.
- **Library proof (P1)**: `Amaru.Treasury.Devnet.SmokeSpec` continues to consume the relocated library functions through `withDevnet`; unchanged here.
- **CLI proof (deferred)**: bash `smoke.sh` lives in #161.

This PR does NOT claim later child-ticket behavior:

- It does NOT introduce `stake-reward-init-wizard` or `governance-withdrawal-init-wizard`. Those are #159 and #160. (The explicit-inter-tx-unsafe pattern is exportable to them.)
- It does NOT introduce `scripts/smoke/smoke.sh`. That is #161.
- It does NOT change `tx-build`. It stays single-intent.
- It does NOT change mainnet or preprod semantics.
- It does NOT introduce internal cross-step simulation, a typed bundle, a state-machine carrier, or any client-side state for resumability. Those concerns are parked in #163.

## On the deferred wizard-vs-stupid-command principle

During this spec phase we established a parent-#156 invariant: *a wizard only asks the operator for genuine human decisions; system-knowable state is derived*. **#158 explicitly does NOT follow that principle.** The operator types seed TxIns, the owner key hash, and the funding seed UTxO directly. The principle remains the design goal for the resumable wizard that #163 will eventually ship, but this PR ships the deliberately-stupid baseline. Memory notes (`feedback_wizard_vs_stupid_command`, `feedback_dont_escalate_carrier_design`, `feedback_client_state_at_build_sign_submit`) record both the principle and the context of this override.

## Non-Goals

- New wizard commands beyond `registry-init-wizard`. (`#159`, `#160`.)
- Bash CLI-driven smoke. (`#161`.)
- Mainnet or preprod safety for the bootstrap actions.
- A bundle / plan / envelope / state-machine carrier (deferred to #163).
- Cross-step simulation; internal derivation of inter-tx state (deferred to #163's resumable wizard).
- Resumability after interruption; multi-sig witness collection state (deferred to #163).
- Modifying the seven `SomeTreasuryIntent` variants from #157.
- Modifying `tx-build`, `witness`, `submit`, or any existing wizard's output format.
- Promoting library `Devnet/*Init.hs` runners as Hackage-public modules.
- Chaining submission inside the wizard.

## Parent Carry-Forward Invariants

From #156, every child carries these invariants; #158 inherits them all *except* the wizard-vs-stupid-command invariant (deferred to #163 — see "On the deferred wizard-vs-stupid-command principle"):

- Shipped CLI bootstrap surface produces unsigned txs only; subcommand → intent JSON → `tx-build` → unsigned CBOR; signing and submission stay on `witness` / `attach-witness` / `submit`.
- Bootstrap transaction construction lives in production library code, not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a shipped surface; today's runners remain library functions consumed by `SmokeSpec` until #161.
- Two proof layers: `SmokeSpec` (library, retained here) and `smoke.sh` (CLI, deferred to #161).
- Network safety: every CLI bootstrap entry refuses non-DevNet networks (fail-closed).

## Assumptions

- The operator's wallet, at each subcommand invocation, contains at least one pure-ADA UTxO large enough to fund the single tx being built. The wizard surfaces a typed shortfall error if not. (Multi-step fund planning is the operator's job; the wizard does no look-ahead.)
- For `mint` and `reference-scripts`, the operator hand-derives the seed TxIns from the previous step's submitted tx (e.g., via `cardano-cli transaction txid --tx-body-file <prev>.tx.cbor.hex`) and types them as flags. The wizard does not validate that the typed values match what seed-split actually produced.
- The owner key hash is the operator's 28-byte payment-key hash, derived externally (e.g., via `cardano-cli address key-hash --payment-verification-key-file ...`) and typed verbatim. The wizard does not derive it from a signing key file.
- The funding seed UTxO for `reference-scripts` is chosen by the operator from their wallet after the prior steps have submitted (the change outputs from `seed-split` and `mint` are the typical candidates).
- Metadata fields (description, justification, destination label, event, label) are optional and default to `Nothing`, consistent with `WithdrawAnswers`.
- The chain network reported by the resolver is `devnet`; mainnet and preprod fail closed.
- The operator carries all inter-step state in their head, in shell scripts, or in a note file. The friction is intentional and informs the #163 spec phase.
