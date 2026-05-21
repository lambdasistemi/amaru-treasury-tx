# Feature Specification: real `ReorganizeIntent` + `Build.Reorganize` + dispatcher wiring

**Feature Branch**: `185-reorganize-core`
**Created**: 2026-05-21
**Status**: Draft
**GitHub Issue**: [#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189) — reorganize transaction end-to-end
**Feature Anchor**: [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
**Sibling Children (later, depend on this slice merging first)**:
- [#186](https://github.com/lambdasistemi/amaru-treasury-tx/issues/186) — `reorganize-wizard` parser scaffold
- [#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187) — `reorganize-wizard` runner + DevNet guard
- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87) — DevNet smoke (live CLI reorganize)
- [#188](https://github.com/lambdasistemi/amaru-treasury-tx/issues/188) — docs + asciinema cast

**Input**: Replace the placeholder `ReorganizeIntent` / `ReorganizeInputs`
shipped in `Amaru.Treasury.Tx.Reorganize` / `Amaru.Treasury.IntentJSON`
with the real typed shapes, add `Amaru.Treasury.Build.Reorganize`
(`runReorganizeBuild` + pure `reorganizeProgram`), and wire the
`SReorganize` arm of the unified `Amaru.Treasury.Build` dispatcher so
the placeholder `DiagnosticUnsupportedAction "reorganize"` error is
replaced by a real per-action build pipeline. The result is that the
library can take a `Reorganize` intent JSON and produce an unsigned
Conway tx body that merges N treasury UTxOs into one continuing output
at the same treasury address.

Mirrors upstream bash
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
+ the shared
[`build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh)
+ `make_redeemer_reorganize` (Sundae @TreasurySpendRedeemer.Reorganize@,
constructor 0, empty fields — already exposed as
`Amaru.Treasury.Redeemer.reorganizeRedeemer`).

> **Scope framing:** this slice is the **library core** only. No
> wizard CLI (#186 / #187), no DevNet smoke (#87), no docs / asciinema
> (#188). After this slice the library can consume a hand-written or
> sibling-produced `Reorganize` intent JSON and emit unsigned Conway
> CBOR; nothing else.

## Upstream parity reference

The upstream bash flow at
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
runs the following ordered steps; this slice ports the **transaction
construction** portion (everything from `make_redeemer_reorganize`
onward) into the Haskell library and leaves the *resolver* portion
(wallet/treasury UTxO discovery, validity-period sampling, signers
lookup from metadata, USDM accumulation) to the wizard child #187:

| Bash phase                             | This slice covers? | Notes |
|----------------------------------------|--------------------|-------|
| `parse_amount`                         | no — wizard #187   | operator-typed `--amount <int> <unit>` |
| `load_metadata` / `load_treasury_config` / `load_permissions_config` | no — wizard #187 | reads `journal/2026/metadata.json` |
| `build_signers $metadata $scope`       | no — wizard #187   | resolves the scope owner key hash from metadata |
| `resolve_fuel`                         | no — wizard #187   | picks the wallet UTxO |
| `select_treasury_utxos`                | no — wizard #187   | accumulates inputs until `acc_lovelace >= amount_lovelace` |
| `compute_validity_period`              | no — wizard #187   | samples tip + adds `--validity-hours` |
| `make_redeemer_reorganize`             | **yes**            | already in `Amaru.Treasury.Redeemer.reorganizeRedeemer` |
| `build_transaction` (cardano-cli args) | **yes**            | port to the `TxBuild q e a` DSL via `reorganizeProgram` |
| `assert_execution_units`               | no — smoke #87     | phase-1 final-checks already runs in `validateFinalPhase1` |
| `write_conway_tx`                      | yes (returned via `BuildResult.brCborBytes`) | library returns the bytes; the wizard / CLI is responsible for envelope shaping |

The "library core" boundary is therefore: **take typed, already-resolved
ledger inputs (treasury UTxOs + lovelace + USDM accumulations + signers
+ deployed-script refs + validity bound), produce unsigned Conway CBOR +
the `BuildResult` shape every other action uses**.

## P1 user story

**As a library consumer of `amaru-treasury-tx`**, I import
`Amaru.Treasury.Build.Reorganize` and observe that `runReorganizeBuild`
on a frozen `ChainContext` plus a `ReorganizeIntent` produces a
`BuildResult` whose `brCborBytes` is the unsigned Conway tx body that:

1. spends the wallet fuel UTxO (also collateral),
2. spends N treasury UTxOs via `spendScript` with the Sundae
   `reorganizeRedeemer` (Constr 0 []),
3. attaches the deployed treasury / registry references (and any
   additional reference inputs the upstream bash wires),
4. wires the permissions withdraw-zero entry exactly as upstream bash
   does (`[NEEDS CLARIFICATION: A]`),
5. emits **one** continuing output at the same treasury address
   carrying the total preserved value (lovelace plus any preserved
   native assets — USDM in the common case),
6. requires the scope-owner signer(s) via `requireSignature`,
7. sets `invalid_hereafter` to the operator-typed validity-bound slot,
8. attaches CIP-1694 rationale metadata under label 1694 (mirroring
   the existing disburse / withdraw runners).

**Why this priority**: parent epic #189 acceptance requires that the
library can produce an unsigned reorganize tx from a `Reorganize`
intent. Without this slice, every sibling child is blocked — the
wizard #186 / #187 has nothing to translate **to**, and the smoke #87
has no shipped command path to drive.

**Independent Test**: library-only. Given a fixture
`ReorganizeInputs` JSON whose treasury UTxOs, treasury address,
deployed-script refs, signers, and validity bound are recorded values,
`runFromIntent ctx` produces `BuildResult` bytes that are
byte-for-byte equal to a committed golden CBOR fixture. No live
network, no wizard, no smoke harness.

**Acceptance Scenarios**:

1. **Given** a fixture `Reorganize` intent JSON that decodes to a
   `ReorganizeInputs` with two treasury UTxOs totalling
   `L1 + L2 = T` lovelace and `U1 + U2 = T_USDM` USDM,
   **When** `runFromIntent ctx (SomeTreasuryIntent SReorganize ti)` is
   called against a frozen `ChainContext` containing those UTxOs,
   **Then** the returned `BuildResult.brCborBytes` is the golden
   reference CBOR; `brTreasuryInputs` is the two UTxOs in input order;
   and the body's outputs list contains exactly one entry at the
   treasury address carrying `T` lovelace and `T_USDM` USDM, plus the
   wallet change output appended by the balancer.
2. **Given** the same fixture, **When** the intent JSON is encoded by
   `toJSONIntent SReorganize ti` and re-decoded by
   `decodeTreasuryIntent`, **Then** the round-trip produces an equal
   `SomeTreasuryIntent SReorganize` (no field is lost, no field
   reordered semantically).
3. **Given** a `Reorganize` intent referencing a treasury UTxO that is
   not present in the frozen `ChainContext` UTxO map, **When**
   `runFromIntent` is called, **Then** the call fails with the
   existing typed `missingUtxosError` listing the missing TxIns
   (mirrors how `runWithdrawAction` already fails closed).
4. **Given** a fresh checkout on `185-reorganize-core` at any commit,
   **When** `nix build .#checks.unit` runs, **Then** it passes; the
   commit message gate (Conventional Commits + `Tasks:` trailer) holds
   for every commit on the branch.

---

## User Story 2 — Dispatcher arm no longer rejects (Priority: P1)

**As a library consumer or sibling-feature implementer**, I observe
that the `SReorganize` arm of `runBuildExcept` (in
`Amaru.Treasury.Build`) is wired to `runReorganizeAction`. There is
no `DiagnosticUnsupportedAction "reorganize"` path left.

**Independent Test**: a unit / golden test invokes
`runFromIntentEither ctx someReorganizeIntent` and asserts the result
is `Right _` (not `Left (BuildError BuildActionReorganize
BuildPhaseUnsupported (DiagnosticUnsupportedAction "reorganize"))`).
Mirror this with a similar negative coverage check via grep
(`grep -nE 'DiagnosticUnsupportedAction +"reorganize"' lib/` returns
zero hits).

**Acceptance Scenarios**:

1. **Given** the merged slice, **When**
   `runFromIntentEither ctx (SomeTreasuryIntent SReorganize ti)` is
   called with a translatable `ti`, **Then** the result is a
   `Right BuildResult` whose `brTxId` is non-empty.
2. **Given** the merged slice, **When**
   `translateIntent SReorganize ti` is called on a well-formed
   `Reorganize` `TreasuryIntent`, **Then** the result is a
   `Right (shared, intent)` with `intent :: ReorganizeIntent`
   (no longer the `Left "translateIntent: 'reorganize' not yet shipped (#46)"`
   stub at `IntentJSON.hs:1468`).

---

## User Story 3 — Intent JSON shape published in the schema (Priority: P2)

**As a downstream consumer of `docs/assets/intent-schema.json`**, I
read the published schema and find that the `reorganize` arm carries
the real field set, not the empty `{}` placeholder.

**Why this priority**: P2 because the published schema is consumed by
downstream tooling (`amaru-treasury-intent-schema` exec + the `dev-assets`
docs site). It is mandatory to ship in this slice — leaving the empty
placeholder in `intent-schema.json` while the Haskell types carry the
real fields would silently lie about the wire format.

**Acceptance Scenarios**:

1. **Given** the merged slice, **When** `just schema-check` runs,
   **Then** it stays green (the regenerated schema matches the
   committed `docs/assets/intent-schema.json`).
2. **Given** the merged slice, **When** a consumer reads the
   `reorganize` arm of `docs/assets/intent-schema.json`, **Then** the
   field names match `ReorganizeInputs`'s JSON shape (treasury UTxOs,
   treasury address, deployed-script refs, validity bound, scope owner
   key hash, optional preserved USDM accumulation — exact set settled
   by `[NEEDS CLARIFICATION: B]`).

---

### Edge Cases

- A `Reorganize` intent JSON that decodes to `ReorganizeInputs` with
  an **empty** treasury-UTxO list must surface a typed translation
  error (it is a degenerate tx: nothing to merge). Either the JSON
  decoder rejects up front, or `translateIntent` does — settled in
  plan.
- A `Reorganize` intent whose treasury UTxOs span more than one
  treasury address (i.e. caller passed UTxOs from two different
  scopes) is structurally invalid for upstream `reorganize.sh`
  (one scope per invocation). It must fail before the build step,
  either at translation or at the resolver layer in #187. For this
  slice, we either reject in `translateIntent` (typed-shape check on
  the resolved address set) or **document** that the wizard child
  is responsible — settled in plan.
- A `Reorganize` intent whose validity-bound slot has already passed
  on the live tip is **not** a concern of the library core. The wizard
  child #187 owns validity sampling; the library accepts whatever slot
  it is handed (matching how `Tx.Withdraw` accepts `wiUpperBound`
  blindly).
- A `Reorganize` intent that references the same TxIn twice in
  `treasuryUtxos` is a degenerate tx; `translateIntent` MAY normalize
  to `nub` or fail; the plan picks one.
- The frozen `ChainContext.ccUtxos` map is missing one or more of the
  treasury UTxOs the intent names — surfaces via the existing
  `missingUtxosError` (already shared with disburse/withdraw).
- The frozen `ChainContext` does not contain the deployed-script
  reference UTxOs the intent names — same `missingUtxosError` path.
- Network safety (mainnet / preprod refusal) is **not** this slice's
  concern; that lives in the wizard child (#187) and in the
  `requireDevnet` dispatcher arm for init sub-actions. The reorganize
  build path itself is network-agnostic at the library layer, matching
  swap / disburse / withdraw.
- CIP-1694 rationale metadata: `runWithdraw` and `runDisburse`
  already accept a `Metadatum` argument from `TranslatedShared.tsRationale`.
  Reorganize MUST follow the same shape — the rationale is encoded
  under label 1694 by `setMetadata label1694 rationale`. The plan
  picks whether the rationale is a typed field on `ReorganizeInputs`
  (operator-supplied) or pulled from the `tsRationale` shared block
  the dispatcher already extracts (settled by
  `[NEEDS CLARIFICATION: C]`).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `Amaru.Treasury.IntentJSON.ReorganizeInputs` MUST be
  replaced with a real record. The record MUST be sufficient to
  reconstruct everything `build_transaction.sh` needs for the
  reorganize case **without** further chain queries: the wallet
  fuel/collateral TxIn, the treasury UTxOs to merge (a non-empty list
  of TxIns), the treasury address, the deployed-script reference
  TxIns (treasury, registry, plus any others upstream wires), the
  scope-owner signer key hash(es), the validity-bound slot, and any
  resolved values needed to construct the continuing-output value
  (lovelace and preserved native-asset accumulations).
- **FR-002**: `Amaru.Treasury.Tx.Reorganize` MUST expose the real
  `ReorganizeIntent` record + the pure `reorganizeProgram :: ReorganizeIntent
  -> TxBuild q e ()`, mirroring `Tx.Withdraw.withdrawProgram` /
  `Tx.Disburse.disburseAdaProgram`. The intent record carries
  already-resolved ledger types (`TxIn`, `Addr`, `Coin`,
  `KeyHash Guard`, `SlotNo`, optional `MultiAsset`).
- **FR-003**: `Amaru.Treasury.Build.Reorganize` MUST exist as a new
  module exposing `runReorganizeBuild` and `runReorganizeAction`,
  mirroring `Amaru.Treasury.Build.Withdraw`'s shape (high-level IO
  runner + lower `ExceptT ActionBuildError IO BuildResult` runner
  the dispatcher composes).
- **FR-004**: `Amaru.Treasury.Build` (the dispatcher) MUST wire its
  `SReorganize` arm to `runReorganizeAction`. The
  `DiagnosticUnsupportedAction "reorganize"` rejection MUST be removed.
  `nestActionBuildError BuildActionReorganize` (or its equivalent)
  wraps the action error, matching the swap/disburse/withdraw arms.
- **FR-005**: `Amaru.Treasury.IntentJSON.translateIntent` MUST handle
  `SReorganize` properly: it returns
  `Right (shared, reorganizeIntent)` for well-formed inputs and a
  typed `Left _` for ill-formed inputs (empty UTxO list, etc — exact
  invariants picked in plan). The current stub
  (`Left "translateIntent: 'reorganize' not yet shipped (#46)"`) MUST
  be removed.
- **FR-006**: `runReorganizeAction` MUST validate the resolved
  treasury UTxOs and reference inputs are present in the
  `ChainContext` UTxO map via the shared `missingUtxosError` helper,
  matching the disburse/withdraw arms.
- **FR-007**: `reorganizeProgram` MUST issue, in this order:
  (a) spend wallet fuel + collateral,
  (b) `spendScript` each treasury UTxO with the Sundae
  `reorganizeRedeemer`,
  (c) attach deployed-script references (treasury, registry, and any
  others upstream wires — exact set settled by
  `[NEEDS CLARIFICATION: A]`),
  (d) wire permissions withdraw-zero exactly as upstream
  (`[NEEDS CLARIFICATION: A]`),
  (e) emit one `payTo treasuryAddress <preservedValue>` continuing
  output,
  (f) `requireSignature` for each scope-owner signer (typically one
  key hash; `build_signers` only appends witnesses for disburse, not
  reorganize),
  (g) `validTo upperBound`.
- **FR-008**: `runReorganizeBuild` MUST go through the standard
  finalisation path:
  `validateFinalPhase1` → `alignCardanoCliBuildFee` →
  `BuildResult` assembly, mirroring `runWithdraw`. CIP-1694 rationale
  metadata is encoded under label 1694 via `setMetadata`.
- **FR-009**: An intent JSON roundtrip golden MUST cover
  encode/decode of a `Reorganize` `SomeTreasuryIntent`:
  `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` on a
  canonical fixture (mirrors the pattern used for stake-reward-init,
  governance-withdrawal-init, etc).
- **FR-010**: A builder materialization golden MUST assert that a
  fixture `ReorganizeIntent` produces the expected continuing-output
  structure and the Sundae `reorganizeRedeemer` byte-for-byte
  (existing redeemer bytes in `Amaru.Treasury.Redeemer` are already
  asserted in tests — the new golden anchors that the produced tx
  body **uses** that redeemer).
- **FR-011**: `docs/assets/intent-schema.json` MUST be regenerated to
  reflect the real `ReorganizeInputs` field set. `just schema-check`
  MUST stay green at every commit.
- **FR-012**: `amaru-treasury-tx.cabal` MUST expose the new
  `Amaru.Treasury.Build.Reorganize` module in the `library` stanza.
- **FR-013**: Every commit on `185-reorganize-core` MUST pass
  `./gate.sh` (Conventional Commit + `Tasks:` trailer enforced by the
  finalization audit).
- **FR-014**: `nix build .#checks.unit` and `nix build .#checks.golden`
  MUST pass at HEAD when the PR is marked ready.

### Non-Functional Requirements

- **NFR-001**: This slice introduces NO new public Hackage modules.
  All new modules live under the existing `amaru-treasury-tx` cabal
  `library` stanza.
- **NFR-002**: This slice introduces NO CLI-facing changes — no new
  flags, no new subcommand, no change to `tx-build`'s parser. (`tx-build`
  itself starts producing a real CBOR for `reorganize` intents because
  the dispatcher arm is wired; that is a behavior change at the
  command layer, not a parser change.)
- **NFR-003**: This slice does NOT touch wizard / parser / runner
  modules (#186 / #187), does NOT touch DevNet smoke
  (`scripts/smoke/`, #87), does NOT touch README / `docs/` (#188).
- **NFR-004**: Library-only behavior changes are bisect-safe. Every
  commit on the branch compiles, and every commit's `./gate.sh` is
  green. Splitting `ReorganizeInputs` rename + dispatcher wire-up
  across commits requires care (see plan): both halves must land in
  one bisect-safe commit, or the gate-aligned slice plan must
  explicitly fold them.
- **NFR-005**: `Amaru.Treasury.Redeemer.reorganizeRedeemer` is
  consumed verbatim — no new redeemer encoding work. The bytes are
  the bash `make_redeemer_reorganize.sh` output, byte-for-byte.

### Key Entities

- **`ReorganizeInputs`** (in `Amaru.Treasury.IntentJSON`): the JSON
  payload shape for the `reorganize` arm of `SomeTreasuryIntent`.
  Carries operator-typed / resolver-translated inputs. Mirrors how
  `WithdrawInputs` / `DisburseInputs` carry their resolved data.
- **`ReorganizeIntent`** (in `Amaru.Treasury.Tx.Reorganize`): the
  typed lift consumed by the build path. Resolved ledger values only.
- **`reorganizeProgram :: ReorganizeIntent -> TxBuild q e ()`**:
  the pure `TxBuild` program — the Haskell port of the bash
  `build_transaction` flow for the reorganize case.
- **`runReorganizeAction` /  `runReorganizeBuild`** (in
  `Amaru.Treasury.Build.Reorganize`): the IO runner that consumes a
  `ChainContext + ReorganizeIntent + Metadatum + Addr` and emits a
  `BuildResult`, mirroring `runWithdrawAction` / `runWithdraw`.

## Deliverables

| Artifact | Purpose | Surfaces touched | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Tx/Reorganize.hs` | real typed intent + pure program | `library` stanza | yes — replaces placeholder |
| `lib/Amaru/Treasury/Build/Reorganize.hs` | new IO runner | `library` stanza | yes — new module |
| `lib/Amaru/Treasury/Build.hs` | dispatcher arm | `library` stanza | yes — replace stub arm |
| `lib/Amaru/Treasury/IntentJSON.hs` | real `ReorganizeInputs` + real `translateIntent` arm | `library` stanza | yes — replaces both placeholders |
| `amaru-treasury-tx.cabal` | expose new module | cabal `library` stanza | yes |
| `test/unit/Amaru/Treasury/Tx/ReorganizeSpec.hs` (or golden under `test/golden/`) | RED → GREEN intent-JSON roundtrip + builder materialization goldens | `test-suite unit-tests` | yes |
| `test/fixtures/reorganize-core/` | canonical reorganize intent JSON + golden CBOR + golden BuildResult shape | new fixture dir | yes |
| `docs/assets/intent-schema.json` | published JSON schema | regen via `just update-schema` | yes — schema-check must stay green |

This slice does **not** ship:

- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (parser — #186)
- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (runner — #187)
- `scripts/smoke/...` reorganize entry (#87)
- `README.md` / `docs/...` reorganize section (#188)
- `docs/assets/asciinema/reorganize.cast` (#188 — and only after the
  shipped CLI exists, which is #187)

**Asciinema scope clarification**: the parent epic #189 calls out a
cast as a first-class deliverable for the operator surface. This
slice (#185) ships **no operator-facing command**, only a library
arm. The cast and prose docs belong to #188 once the wizard surface
exists. This is consistent with the resolve-ticket vertical-deliverables
rule because the peer surface in this slice is the **library + golden
tests**, not an executable; the executable surface is #186/#187, where
the cast and docs follow.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The two placeholder data declarations in
  `lib/Amaru/Treasury/Tx/Reorganize.hs` (`data ReorganizeIntent = ReorganizeIntent`)
  and `lib/Amaru/Treasury/IntentJSON.hs` (`data ReorganizeInputs = ReorganizeInputs`)
  are both replaced with real records carrying named fields.
  `grep -nE '^data Reorganize(Intent|Inputs) = Reorganize\1$' lib/` returns
  zero hits at HEAD.
- **SC-002**: `grep -nE 'DiagnosticUnsupportedAction +"reorganize"' lib/`
  and `grep -n "'reorganize' not yet shipped" lib/` both return zero
  hits at HEAD.
- **SC-003**: A golden CBOR fixture
  `test/fixtures/reorganize-core/<name>.tx.cbor.hex` exists and
  `nix build .#checks.golden` reproduces its bytes from
  `runFromIntent` on a committed fixture JSON.
- **SC-004**: A round-trip property
  (`decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right`) covers
  the `Reorganize` action, mirroring the existing per-action
  round-trip pattern.
- **SC-005**: `just schema-check`, `nix build .#checks.unit`,
  `nix build .#checks.golden`, `nix build .#checks.lint`, and
  `just smoke` (the existing shipped-CLI smoke set) stay green at
  every commit on the branch.
- **SC-006**: The reorganize redeemer bytes emitted by the produced
  tx body match `Amaru.Treasury.Redeemer.reorganizeRedeemer`
  byte-for-byte (Constr 0 [], CBOR `d87980`).
- **SC-007**: The continuing-output value on the built tx equals the
  total lovelace of the spent treasury UTxOs plus the total preserved
  USDM (when present), to the asset.
- **SC-008**: The unified `Amaru.Treasury.Build` dispatcher tests
  (if any exist for the other arms) extend to cover the
  `SReorganize` arm; otherwise a focused test on
  `runFromIntentEither ctx (SomeTreasuryIntent SReorganize _)` proves
  the wire-up.

## Command-Recovery Posture

This slice does NOT ship an operator-facing command. The operator
recovery surface lives in #186 / #187 (`reorganize-wizard`) and the
DevNet proof in #87. The P1 user story here is library-facing
(`runReorganizeBuild` on a `ChainContext + ReorganizeIntent`); the
proof is a CBOR golden + roundtrip property + dispatcher unit test.

`tx-build --intent` becomes capable of consuming a `Reorganize` JSON
once this slice merges — that is a downstream side-effect of wiring
the dispatcher arm, not a new CLI surface. The shipped CLI parser is
unchanged.

## Clarifications

### Open clarifications (forwarded to epic owner via Q-001-spec-ready)

- **[NEEDS CLARIFICATION: A] — Permissions withdraw-zero parity**.
  Upstream
  [`build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh)
  is shared across `reorganize.sh` / `disburse.sh`, and includes
  `--withdrawal $permissions_stake_address+0` plus the
  `permissions_reference` read-only ref every call, including
  reorganize. The Sundae validator's `Reorganize` arm does **not**
  require permissions withdraw (only owner multisig on the spend).
  Two viable choices:
  - **(A1) Byte-for-byte parity**: wire permissions withdraw-zero in
    `reorganizeProgram` (extra reference input + extra script
    withdrawal + extra permissions reward-account field on
    `ReorganizeIntent`). Matches upstream bash exactly. Strictly
    larger tx (more script eval). Required if the smoke #87 will
    diff against bash-built bytes.
  - **(A2) Minimal validator-spec build**: skip permissions
    withdraw-zero, mirroring the issue's "scope-owner-signed only"
    framing. Smaller tx, fewer reference inputs. The intent JSON
    payload shrinks by `permissionsRewardAccount` +
    `permissionsDeployedAt`. Does not match bash byte-for-byte.

  Recommend **A1** unless the epic owner explicitly opts for A2 —
  byte-for-byte upstream parity is the safer default for the smoke
  layer #87 and minimises validator surprises if Sundae tightens the
  reorganize spec. (Plan locks once answered.)

- **[NEEDS CLARIFICATION: B] — USDM in the intent payload**.
  `reorganize.sh` accepts `<AMOUNT> <UNIT>` and `select_treasury_utxos`
  accumulates `acc_lovelace` and `acc_usdm` from the picked treasury
  UTxOs, then writes the continuing output as
  `$treasury_address+$acc_lovelace[+$acc_usdm $USDM_POLICY.$USDM_TOKEN]`.
  Two viable shapes for `ReorganizeInputs`:
  - **(B1) Resolved totals carried explicitly**: `continuingLovelace
    :: Coin`, `continuingUsdm :: Integer` (optional), `usdmPolicy ::
    Maybe PolicyID`, `usdmAsset :: Maybe AssetName`. The wizard
    accumulates and writes them in.
  - **(B2) Recompute from frozen UTxO map**: only carry
    `treasuryUtxos :: [TxIn]` and recompute the totals at build time
    from `ChainContext.ccUtxos`. Smaller payload but couples build to
    chain state shape.

  Recommend **B1** (carries the operator-resolved totals exactly,
  matches how `DisburseUsdmPayload` already represents
  multi-asset payloads, and means the library core needs no
  USDM-policy knowledge of its own). Open in case the epic owner
  prefers B2 to keep the intent shape minimal.

- **[NEEDS CLARIFICATION: C] — Rationale source**.
  `runWithdraw` / `runDisburse` take a `Metadatum` argument
  (`tsRationale shared`). For the reorganize arm, does the rationale
  come from `TranslatedShared` (operator-supplied at the intent JSON
  layer, same as other actions) — **(C1)** — or from a dedicated
  `reorganizeRationale` field on `ReorganizeInputs` — **(C2)**?

  Recommend **C1** (uniformity across all four shipped-CLI actions;
  no new field on `ReorganizeInputs`; the wizard #187 plumbs
  rationale through the existing shared block).

### Resolved (answered inline during interview)

_(none yet — to be filled when Q-001-spec-ready answers come back)_

## Non-Goals

- `reorganize-wizard` parser, runner, network guard, validity sampling,
  treasury UTxO selection. (#186 / #187.)
- DevNet smoke that drives the shipped CLI against a live chain. (#87.)
- README / `docs/` updates, asciinema cast. (#188.)
- USDM-specific reorganize behaviour beyond preserving the asset in
  the continuing output.
- Multi-scope reorganize (one scope per invocation, mirroring
  upstream bash).
- Cross-step simulation; client-side resumable state (parked under
  #163).
- New redeemer encodings — `reorganizeRedeemer` already exists.
- Touching `Amaru.Treasury.Devnet.SmokeSpec` (the library-proof
  layer for other actions). Reorganize gets a library proof here via
  goldens + roundtrip; a SmokeSpec entry is optional and parked unless
  the epic owner asks for one in Q-001.

## Parent Carry-Forward Invariants

From epic #189, every child carries these invariants; #185 inherits
them all (the network-safety invariant is satisfied trivially here
because this slice ships no operator-facing command):

- **Reorganize tx is the simplest of the three operational actions**:
  single continuing output back to the same treasury address; scope-owner
  signed; no beneficiary; no unit branching.
- **Construction lives in production library code**, never in smoke
  specs. This slice puts the construction in
  `lib/Amaru/Treasury/Build/Reorganize.hs`, mirroring the existing
  disburse / swap / withdraw build paths.
- **Shipped CLI surface produces unsigned txs only.** This slice does
  not touch the CLI surface; the produced `BuildResult.brCborBytes`
  is an unsigned Conway tx.
- **Network safety is fail-closed** at the wizard surface (#187), not
  here. The library core is network-agnostic, matching swap /
  disburse / withdraw.
- **Operator-typed inter-tx values.** The wizard child #187 is
  responsible for treasury-UTxO selection, validity bound, and
  funding seed; this slice's `ReorganizeInputs` is the resolved
  ledger snapshot the wizard hands to the library.
- **Phase-1 validation includes execution units** (smoke layer #87).
  This slice's `runReorganizeBuild` already invokes
  `validateFinalPhase1`, matching the disburse / withdraw runners.

## Assumptions

- The frozen `ChainContext` produced by the wizard child (#187)
  contains every UTxO `ReorganizeIntent` references: the wallet fuel,
  every treasury UTxO to merge, and every deployed-script reference.
  This slice's library core surfaces a typed `missingUtxosError`
  rather than silently building an incoherent tx.
- The scope-owner signer key hash is known to the wizard child
  (extracted from `metadata.json` upstream via `build_signers`); this
  slice's `ReorganizeIntent` carries it as `KeyHash Guard`.
- The Sundae `Reorganize` redeemer (Constr 0 []) is the correct
  redeemer for every treasury input on a reorganize tx — already
  asserted by `Amaru.Treasury.Redeemer` tests.
- The validator's reorganize arm requires only the scope-owner
  multisig signature; permissions withdraw-zero (if included per
  clarification A) is a parity / safety extra, not a validator
  requirement.
- The intent JSON shape may grow in later releases (the
  encode/decode roundtrip golden anchors it). This slice produces the
  first non-empty shape; downstream tooling regenerates against the
  published schema.
