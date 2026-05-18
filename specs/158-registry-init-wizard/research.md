# Research: registry-init-wizard

**Branch**: `158-registry-init-wizard` | **Date**: 2026-05-18 | **Spec**: [spec.md](./spec.md)

## Scope

Phase-0 research for #158. Resolves the open technical decisions before plan-phase implementation slices begin.

## Decisions

### D1 — CLI shape: three subcommands

**Decision**: `amaru-treasury-tx registry-init-wizard` exposes three optparse-applicative subcommands: `seed-split`, `mint`, `reference-scripts`. Each subcommand has its own flag set; flags shared across the three are inherited via a common parser combinator.

**Rationale**: Three subcommands is the idiomatic optparse-applicative shape for a discriminated CLI. Each subcommand gets its own `--help`, its own flag set, and matches how the seven flat sub-action intents already shipped in #157 are structured at the JSON layer. The alternative (one command with `--sub-action <name>`) would muddle the help text and force fancier validation when the sub-action selects which flags are required.

**Alternatives considered and rejected**:
- *Single command with `--sub-action seed-split | mint | reference-scripts` flag*: harder to surface per-sub-action `--help`, harder to gate which flags are required by sub-action.
- *Three independent top-level commands* (`registry-init-seed-split-wizard`, etc.): clutters the top-level command list; obscures that the three belong to one logical action.
- *One wizard producing all three intents in one Q&A* (the rejected "one-shot wizard" design from earlier spec drafts): requires the wizard to simulate cross-step tx bodies internally to derive seed TxIns and the planned reference-scripts funding seed. This was the design that surfaced the application-state question and was deliberately rejected for #158 in favour of the explicit-inter-tx-unsafe baseline. The application-state work is parked in [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).

### D2 — Owner key hash is operator-typed, not derived

**Decision**: `mint --owner-key-hash <hex28>` takes a 56-character hex string (28 bytes); the wizard does NOT derive the key hash from a `--signing-key-file`.

**Rationale**: Consistent with the *explicit-inter-tx-unsafe* design principle. The operator already runs `cardano-cli address key-hash` (or equivalent) externally before invoking the wizard. Keeping the wizard as a pure flag→JSON translator avoids reading signing keys at wizard time and avoids confusion about which key the wizard "signed" with (it never signs anything).

**Alternatives considered and rejected**:
- *Derive from `--signing-key-file`*: pulls the wizard into key-format territory (TextEnvelope vkey/skey parsing), adds a file IO step, and breaks the principle that the wizard takes operator-typed inter-tx state. Rejected here; the resumable wizard in #163 will reconsider.

### D3 — Reference-scripts funding seed: `--funding-seed-txin <txid#ix>`

**Decision**: `reference-scripts --funding-seed-txin <txid#ix>` is operator-typed. The operator selects the UTxO to spend as the funding input for the reference-scripts publication tx. Typical operator workflow: pick a change output from `seed-split` or `mint` after submission.

**Rationale**: The library core `buildReferenceScriptsCore` takes a single funding UTxO; the operator-typed flag mirrors that input directly. The wizard's resolver does NOT scan the wallet to pick a funding UTxO automatically — that would be derivation across sub-step state, which #158 explicitly excludes.

**Alternatives considered and rejected**:
- *Wizard picks largest pure-ADA UTxO automatically*: cross-step derivation; rejected per the explicit-inter-tx-unsafe directive.
- *Defer funding selection to `tx-build`*: would require an intent shape with a "select-at-build-time" marker, which doesn't exist in #157's `RegistryInitReferenceScriptsInputs` and is out of scope.

### D4 — Parser reuse: `<txid#ix>` and hex-28

**Decision**: Reuse existing parsers from `Amaru.Treasury.LedgerParse`: `txInFromText :: Text -> Either String TxIn` for `"txid#ix"` and `keyHashFromHex :: Text -> Either String (KeyHash Witness)` for 28-byte hex. Slice 3's subagent brief points at these exact symbols.

**Rationale**: `lib/Amaru/Treasury/LedgerParse.hs` already exports both. Re-exporting `parseTxIn` from `IntentJSON` is internal to the JSON decoder path; the wizard CLI parsers should import directly from `LedgerParse`. Two independent implementations would drift.

**Alternatives considered and rejected**:
- *Reinvent in the wizard CLI module*: silent drift risk; rejected.
- *Import via `IntentJSON.parseTxIn` re-export*: works but couples the wizard parsers to an internal decoder re-export; prefer the direct `LedgerParse` import.

### D5 — Resolver shape: reuse the shared wizard helpers

**Decision**: The wizard's resolver layer mirrors `Amaru.Treasury.Tx.WithdrawWizard`'s resolver shape. Shared helpers (`registryViewFromVerified`, `selectWallet`, `addrNetwork`) live in `Amaru.Treasury.Tx.SwapWizard` and are re-exported by `WithdrawWizard`; import them directly from `SwapWizard` (the canonical home), not transitively. `verifyRegistry` lives in its own module and is already used at the CLI layer. If three wizards eventually need a private helper that's currently a local function, extract to a new `Amaru.Treasury.Tx.WizardCommon` module — but only when forced, not preemptively.

**Rationale**: The resolver work (verify registry, query wallet, sample upper-bound slot, derive network) is identical across all wizards. Importing from the canonical home (`SwapWizard`) avoids a re-export chain. Premature abstraction (a shared `WizardResolver` typeclass) is the wrong move at three wizards.

**Alternatives considered and rejected**:
- *Build a shared `WizardCommon` module up front*: premature abstraction.
- *Copy resolver code into the new module*: silent drift risk on subsequent wizard ticket (#159, #160).

### D6 — Golden fixtures derived from `RegistryInitFixtures`

**Decision**: New wizard fixtures under `test/fixtures/registry-init-wizard/` are derived from the same underlying inputs `test/golden/Support/RegistryInitFixtures.hs` already uses for the library-core goldens shipped in #157. A small test-support helper materializes both forms (library-core fixture; wizard-answers fixture) from the same source.

**Rationale**: The wizard parity goldens hold "wizard intent → tx-build CBOR" against "library core CBOR" on equivalent inputs. If the two fixture sets drift independently, the proof becomes meaningless. Co-derivation is the cheap fix.

**Alternatives considered and rejected**:
- *Hand-roll the wizard fixtures independently*: silent drift.
- *Have the test invoke the wizard at build time to generate the golden*: adds a node-touching step inside the golden suite; rejected for CI simplicity.

### D7 — No internal cross-step simulation; grep-enforced

**Decision**: NFR-006 / SC-007 forbid the wizard module source from referencing `buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore`. Enforced by a unit test that reads the wizard source file and asserts no occurrences (`Test.Hspec` + `Data.Text.IO.readFile` + `Data.Text.isInfixOf`).

**Rationale**: Without this check, a well-intentioned future change could quietly re-introduce wizard-internal simulation, which would put #158 across the line into the wizard-vs-stupid-command territory it explicitly excludes. The grep makes the design constraint mechanical.

**Locked decision (analyzer-confirmed)**: the enforcement is a **unit test only**, not a duplicate `gate.sh` step. The unit test reads the wizard module sources and asserts no occurrences of the three core symbol names. `./gate.sh` runs the test suite, so the invariant is checked transitively.

**Alternatives considered and rejected**:
- *Convention only (no test)*: weak; future contributors may not read this plan.
- *gate.sh-only grep*: works but adds a non-test invariant; a unit test is more visible to future contributors and integrates with the normal failure surface.
- *Both unit test AND gate.sh grep*: duplicate work; rejected for cleanliness.

## Open Items

None. All `[NEEDS CLARIFICATION]` markers from earlier spec drafts have been resolved (sub-action surface, carrier shape, owner-key-hash provenance, funding-seed-txin provenance, resolver reuse).
