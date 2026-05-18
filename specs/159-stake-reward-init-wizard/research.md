# Research: stake-reward-init-wizard

**Branch**: `159-stake-reward-init-wizard` | **Date**: 2026-05-18 | **Spec**: [spec.md](./spec.md)

## Scope

Phase-0 research for #159. Resolves the open technical decisions before plan-phase implementation slices begin. Most decisions carry over from #158 (PR [#165](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165)); only the differences are spelled out below.

## Decisions

### D1 — CLI shape: two subcommands

**Decision**: `amaru-treasury-tx stake-reward-init-wizard` exposes two optparse-applicative subcommands: `script-account`, `plain-account`. Each subcommand has its own flag set; flags shared across the two are inherited via a common parser combinator. The two subcommands are independent — no required ordering at the wizard layer (NFR-007).

**Rationale**: Two subcommands is the idiomatic optparse-applicative shape and matches how the two flat sub-action intents already shipped in #157 (`StakeRewardInitScriptAccountInputs`, `StakeRewardInitPlainAccountInputs`) are structured at the JSON layer. The alternative (one command with `--sub-action <name>`) would muddle the help text and force fancier validation when the sub-action selects which flags are required.

**Why simpler than #158**: #158 had three sub-actions chained by operator-typed seed TxIns; #159's two sub-actions are independent — neither feeds into the other. The structural simplification is intrinsic, not a design choice.

**Alternatives considered and rejected**:
- *Single command with `--sub-action script-account | plain-account` flag*: harder to surface per-sub-action `--help`; gains nothing.
- *Two independent top-level commands* (`stake-reward-init-script-account-wizard`, etc.): clutters the top-level command list; obscures that the two belong to one logical action.
- *Combined wizard producing both intents in one Q&A*: would require the wizard to derive cross-action state and would slide back into wizard-vs-stupid-command territory deliberately deferred to #163.

### D2 — Registry artifact is operator-typed via `--registry <path/registry.json>`

**Decision**: Both subcommands accept `--registry <path>` pointing at the `registry.json` artifact published by a prior successful `registry-init-wizard reference-scripts` submission. The wizard parses the file with the existing `Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry`, which already enforces `phase == "registry-init"` and `network == "devnet"` and extracts the four anchors (`treasuryRef`, `permissionsRef`, `treasuryScriptHash`, `permissionsScriptHash`). The wizard does **not** re-verify the parsed values against chain state (see D8).

**Rationale**: The registry artifact is the natural carrier of "what #158's bootstrap produced." Both sub-actions need values from it (script-account needs `treasuryRef` + `treasuryScriptHash`; plain-account needs `permissionsScriptHash`). Re-using `readDevnetStakeRewardRegistry` keeps the parser shape consistent with the live submitter — a single source of truth for the artifact's JSON shape, phase gate, and network gate.

**Alternatives considered and rejected**:
- *Operator types each registry-derived value as separate flags* (`--treasury-ref-txin`, `--treasury-script-hash`, `--permissions-script-hash`): pushes more operator typing for no gain — these values *do* live in the artifact, and the operator has the artifact on disk.
- *Wizard queries chain to enumerate registry anchors*: cross-step derivation from chain state; rejected per the explicit-inter-tx-unsafe directive (the registry artifact path is the operator's commitment to which bootstrap they're following up on).
- *Wizard re-verifies registry-derived values against chain* (call `verifyRegistry` or equivalent): see D8 — rejected.

### D3 — Funding seed: `--funding-seed-txin <txid#ix>`

**Decision**: Both subcommands accept `--funding-seed-txin <txid#ix>` operator-typed. The operator selects the UTxO to spend as the funding input (also collateral for `script-account`). Typical operator workflow: pick a change output from a recent wallet submission.

**Rationale**: The library cores `buildStakeRewardScriptAccountCore` and `buildStakeRewardPlainAccountCore` each take a single funding UTxO; the operator-typed flag mirrors that input directly. The wizard's resolver does NOT scan the wallet to pick a funding UTxO automatically — that would be derivation across sub-step state, which #159 explicitly excludes. This is unchanged from #158's D3.

**Alternatives considered and rejected**:
- *Wizard picks largest pure-ADA UTxO automatically*: cross-step derivation; rejected per the explicit-inter-tx-unsafe directive.
- *Defer funding selection to `tx-build`*: would require an intent shape with a "select-at-build-time" marker, which doesn't exist in #157's `StakeRewardInit*Inputs` and is out of scope.

### D4 — Parser reuse: `<txid#ix>` from LedgerParse

**Decision**: Reuse `Amaru.Treasury.LedgerParse.txInFromText :: Text -> Either String TxIn` for the `--funding-seed-txin` parser via `optparse-applicative`'s `eitherReader`. #159 does **not** need the hex-28 owner-key-hash parser — there is no `--owner-key-hash` flag (the script witnesses come from the registry-resident script anchors, not from operator-typed key hashes).

**Rationale**: Same as #158's D4 — `LedgerParse` is the canonical home, used by both the JSON decoder path and now the wizard CLI path. Two independent TxIn-text parsers would drift.

**Alternatives considered and rejected**:
- *Reinvent in the wizard CLI module*: silent drift risk; rejected.

### D5 — Resolver shape: reuse the shared wizard helpers

**Decision**: The wizard's resolver layer mirrors `Amaru.Treasury.Tx.RegistryInitWizard`'s resolver shape (which itself imports `selectWallet`, `addrNetwork`, etc. from `Amaru.Treasury.Tx.SwapWizard` directly). Import the shared helpers from `SwapWizard` (the canonical home), not transitively via `RegistryInitWizard` or `WithdrawWizard`. **Do not extract a `WizardCommon` module** — #158's plan deferred that abstraction until forced, and #159 is no different.

**Rationale**: The resolver work (network probe, query wallet, sample upper-bound slot, derive funding address) is identical across wizards. Importing from the canonical home avoids a re-export chain. The shared-helper extraction is a separate refactor and is not in scope for #159.

**Alternatives considered and rejected**:
- *Build a shared `WizardCommon` module up front*: premature abstraction; explicitly deferred by #158's plan.
- *Copy resolver code into the new module*: silent drift risk on subsequent wizard ticket (#160).

### D6 — Golden fixtures derived from `Support.StakeRewardInitFixtures`

**Decision**: New wizard fixtures under `test/fixtures/stake-reward-init-wizard/` are derived from the same underlying inputs the existing `test/golden/Support/StakeRewardInitFixtures.hs` (shipped in #157) already uses for the library-core goldens. A new helper `test/golden/Support/StakeRewardInitWizardFixtures.hs` (Slice 2, extended in Slice 3) materializes the wizard-`Answers + Env` fixture from the same underlying material.

**Rationale**: The wizard parity goldens hold "wizard intent → tx-build CBOR" against "library core CBOR" on equivalent inputs. Independent fixture authoring would make the proof meaningless. This mirrors #158's D6 exactly — `Support.RegistryInitFixtures` ↔ `Support.RegistryInitWizardFixtures`.

**Alternatives considered and rejected**:
- *Hand-roll the wizard fixtures independently*: silent drift.
- *Have the test invoke the wizard at build time to generate the golden*: adds a node-touching step inside the golden suite; rejected for CI simplicity.

### D7 — No internal cross-step simulation; grep-enforced

**Decision**: NFR-006 / SC-007 forbid the wizard module source from referencing `buildStakeRewardScriptAccountCore` and `buildStakeRewardPlainAccountCore`. Enforced by a unit test that reads the wizard source files (`lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` and `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`) and asserts no occurrences (`Test.Hspec` + `Data.Text.IO.readFile` + `Data.Text.isInfixOf`).

**Rationale**: Same as #158's D7. Without this check, a well-intentioned future change could quietly re-introduce wizard-internal simulation, putting #159 across the line into the wizard-vs-stupid-command territory it explicitly excludes. The grep makes the design constraint mechanical.

**Locked decision (carried from #158)**: the enforcement is a **unit test only**, not a duplicate `gate.sh` step. The unit test reads the wizard module sources and asserts no occurrences of the two core symbol names. `./gate.sh` runs the test suite, so the invariant is checked transitively.

**Alternatives considered and rejected**:
- *Convention only (no test)*: weak; future contributors may not read this plan.
- *gate.sh-only grep*: works but adds a non-test invariant; a unit test is more visible to future contributors and integrates with the normal failure surface.
- *Both unit test AND gate.sh grep*: duplicate work; rejected for cleanliness.

### D8 — No registry chain re-verification at wizard layer

**Decision**: The wizard does **not** call `verifyRegistry` (or any equivalent chain re-verification) against the values it extracts from `--registry`. The operator's commitment to "this is the registry artifact I bootstrapped" is honored as-is. The only chain query in the resolver is the network probe (D9) and the standard wallet UTxO query for funding-address resolution / shortfall check.

**Rationale**: Re-verifying the registry against chain would (a) duplicate the work `readDevnetStakeRewardRegistry`'s parser + the live submitter already do at submission time, (b) push the wizard back into a "wizard simulates / validates inter-step state" posture that #156's stupid-baseline directive forbids, and (c) couple the wizard to an additional set of chain RPC calls that have no equivalent in #158's existing wizards. The cost of a stale/wrong `--registry` path is borne at `tx-build` (best case — reference-script lookup fails) or at on-chain validation (worst case — script-hash mismatch). That cost is the "unsafe" in the design framing.

**Rationale (positive)**: The `phase == "registry-init"` and `network == "devnet"` gates in `readDevnetStakeRewardRegistry` already catch the most common operator mistake (pointing `--registry` at a non-bootstrap file or a file from a different network). Anything beyond that is the operator's responsibility per the explicit-inter-tx-unsafe baseline.

**Alternatives considered and rejected**:
- *Call `verifyRegistry` against chain*: rejected per the rationale above. The cost is paid downstream at `tx-build` and on-chain.
- *Cross-check the registry's anchor TxIns against the chain's UTxO set*: same problem — extra RPC, slides into simulation territory.

### D9 — Network probe at the resolver layer (devnet-only guard)

**Decision**: Both subcommands MUST query the chain at resolver time to confirm the connected network is `devnet`. Non-DevNet networks (mainnet, preprod, preview) fail closed with a typed `StakeRewardInitNonDevnetNetwork` error before any file is written. This is the same fail-closed posture as #158's `RegistryInitWizardNetworkGuardSpec`, and is defense-in-depth over the `requireDevnet` guard already enforced by `Build.hs`'s `tx-build --intent` dispatcher.

**Rationale**: Parent #156 invariant: "every CLI bootstrap entry refuses non-DevNet networks (fail-closed)." Even though `readDevnetStakeRewardRegistry` gates the `--registry` file at parse time, the operator could supply a devnet-shaped registry and then point at a non-devnet socket — without this guard, the wizard would happily write an intent for the wrong chain. Fail-closed at the wizard layer means the operator never gets a half-resolved intent on disk for the wrong network.

**Alternatives considered and rejected**:
- *Rely on `Build.hs:requireDevnet`*: works but lets the operator generate a non-DevNet intent file on disk, surfacing the error one command later; worse UX. Defense-in-depth is cheap here.
- *Trust the registry artifact's network field*: same problem — registry file content can be devnet while the chain target is not.

### D10 — Subcommand independence (no required ordering)

**Decision**: The wizard MUST NOT enforce any required ordering between `script-account` and `plain-account` invocations. Either may be invoked first; both are equally valid against the same `registry.json`.

**Rationale**: At the library layer (`setupDevnetStakeRewards` in `Devnet/StakeRewardInit.hs`), the production end-to-end runner does both certs in **one** setup transaction. #157 split that into two independent intents to align with the stupid-baseline directive (one bare `SomeTreasuryIntent` per intent file). The two sub-actions register two **different** reward accounts (treasury vs permissions); neither depends on the other being registered first. Enforcing an order at the wizard layer would be wizard-internal state, which is exactly what #159 (and #158) explicitly forbid.

**Practical consequence**: Operators may run the two subcommands in either order during a single bootstrap session. #161's bash smoke will pick one canonical order (typically `script-account` then `plain-account`, matching the order they appear in the production submitter), but that ordering is `smoke.sh`'s convention, not the wizard's contract.

**Alternatives considered and rejected**:
- *Wizard checks chain to detect "is the other reward account already registered?"*: cross-step derivation; rejected per stupid-baseline.
- *Wizard records a local file marker after each invocation*: client state; deferred to #163.

## Open Items

None. The specs-phase clarifications and the decisions above resolve every `[NEEDS CLARIFICATION]` candidate (registry-artifact carrier, subcommand independence, no chain re-verification, network-probe scope). The implementation slices in `plan.md` operate on top of these decisions without further open questions.
