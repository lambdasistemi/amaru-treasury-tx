# Feature Specification: Flatten Devnet Supercommand & Add Init Intent Encodings

**Feature Branch**: `157-flatten-devnet-cli`
**Created**: 2026-05-17
**Status**: Draft
**GitHub Issue**: [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Input**: Drop the nested `amaru-treasury-tx devnet <action>` supercommand from the shipped CLI surface, add `SomeTreasuryIntent` variants and JSON round-trip for the three init actions (`registry-init`, `stake-reward-init`, `governance-withdrawal-init`), and prove `tx-build --intent <bootstrap-intent.json>` builds the same unsigned tx CBOR hex the corresponding library function builds today. Relocate the end-to-end `lib/Amaru/Treasury/Devnet/*Init.hs` and `DisburseSubmit.hs` runners so they are no longer reachable from the shipped CLI; `SmokeSpec` keeps consuming them as library functions.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Build Each Init Tx From An Intent JSON Through `tx-build` (Priority: P1)

As a release maintainer running the local DevNet bootstrap from the
shipped CLI, I need `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>`
to construct the unsigned registry-init, stake-reward-init, or
governance-withdrawal-init transaction so the operator path matches the
existing wizard → `tx-build` shape used by `swap`, `withdraw`, and
`disburse`, with the in-process `runDevnet*Init` runners no longer
exposed as a parallel CLI surface.

**Why this priority**: This is the paramount user-facing surface
change of #157. Parent ticket #156 makes the bootstrap actions
first-class user-facing commands; without an intent encoding and the
`tx-build` path, the later wizard tickets (#158–#160) cannot deliver
their `intent.json` artifacts to a build step. The unsigned-tx CBOR
hex produced by `tx-build` is the contract every other operator step
(witness, attach-witness, submit) already consumes.

**Independent Test**: With the legacy `lib/Amaru/Treasury/Devnet/*Init.hs`
runner producing reference CBOR for the same logical action under a
fixed seed, run `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>`
for each of the three init actions and verify the unsigned tx CBOR hex
is byte-identical. The legacy runner stays callable from `SmokeSpec` to
generate the reference; only the CLI exposure goes away.

**Acceptance Scenarios**:

1. **Given** a `registry-init` `bootstrap-intent.json` produced by
   tooling that calls the relocated library code, **When** an operator
   runs `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>`
   against a live DevNet socket, **Then** the produced unsigned tx
   CBOR hex equals the CBOR the corresponding library function builds
   for the same logical inputs, byte-for-byte.
2. As (1), **for** `stake-reward-init`.
3. As (1), **for** `governance-withdrawal-init`.
4. **Given** any of the three init `bootstrap-intent.json`s, **When**
   they are round-tripped through `encodeSomeTreasuryIntent` /
   `decodeTreasuryIntent`, **Then** the decoded value is observationally
   equal to the input (`encode . decode == decode . encode` on the JSON
   shape).
5. **Given** an `bootstrap-intent.json` with `network` set to
   `mainnet` or `preprod`, **When** an operator runs `tx-build` against
   it, **Then** the build fails closed with a typed error before any
   N2C connection or transaction construction.

---

### User Story 2 — Remove `devnet` Supercommand From The Shipped Parser (Priority: P1)

As an operator inspecting `amaru-treasury-tx --help`, I need the
`devnet` nested supercommand and its four children
(`registry-init`, `stake-reward-init`, `governance-withdrawal-init`,
`disburse-submit`) to be absent from the shipped parser so that the
only operator path to a bootstrap transaction is the unified
intent → `tx-build` pipeline.

**Why this priority**: Parent ticket #156 explicitly forbids parallel
operator surfaces. Leaving the in-process runners as a CLI option
would defeat the wizard / `tx-build` contract and re-introduce CLI
glue that constructs transactions out of band.

**Acceptance Scenarios**:

1. **Given** the shipped `amaru-treasury-tx` binary at this PR's HEAD,
   **When** an operator runs `amaru-treasury-tx --help`, **Then**
   the output contains no `devnet` command and no
   `registry-init`, `stake-reward-init`,
   `governance-withdrawal-init`, or `disburse-submit` subcommand.
2. **Given** the shipped binary, **When** an operator runs
   `amaru-treasury-tx devnet registry-init …`, **Then** the parser
   rejects the command with an unrecognized-subcommand error (no
   silent fallthrough).
3. **Given** the shipped binary, **When** an operator runs
   `amaru-treasury-tx tx-build --help`, **Then** the help text
   continues to mention `--intent` as the source of truth for the
   action.

---

### User Story 3 — `SmokeSpec` Keeps Working Via Library Functions (Priority: P1)

As a maintainer of the DevNet proof harness, I need
`Amaru.Treasury.Devnet.SmokeSpec` to keep compiling and passing while
calling the relocated `runDevnet*Init` and `runDevnetDisburseSubmit`
functions directly as library functions (no CLI shelling, no
`amaru-treasury-tx devnet …` invocation), so the library-level DevNet
proof keeps gating CI through `nix build .#checks.*`.

**Why this priority**: Parent #156 commits to two proof layers
(library `SmokeSpec` + bash `smoke.sh` from #161). Removing
`SmokeSpec`'s library access in this PR would orphan the parent's
library-proof commitment before #161 lands the bash equivalent.

**Acceptance Scenarios**:

1. **Given** the relocated runners under `lib/Amaru/Treasury/Devnet/`,
   **When** `SmokeSpec` is built, **Then** it imports the runners as
   library functions and never shells out to `amaru-treasury-tx`.
2. **Given** a local DevNet via `withDevnet`, **When** `SmokeSpec`
   executes the registry-init → stake-reward-init →
   governance-withdrawal-init → disburse-submit sequence by calling
   the relocated library functions, **Then** the run completes with
   the same artifacts and post-conditions today's `SmokeSpec` asserts.

---

### User Story 4 — Docs Reflect The New Operator Path (Priority: P2)

As an operator reading `README.md` and `docs/local-devnet-smoke.md`, I
need the documentation to describe the new operator path
(`tx-build --intent <bootstrap-intent.json>` for the unsigned tx),
to mark the legacy `devnet <action>` subcommands as removed, and to
forward-reference the wizard tickets (#158–#160) for the
`intent.json` producers.

**Acceptance Scenarios**:

1. **Given** the merged PR, **When** an operator reads `README.md`,
   **Then** any `amaru-treasury-tx devnet …` invocation has been
   replaced by `amaru-treasury-tx tx-build --intent …`, with a
   pointer to the wizard tickets for the producer side.
2. **Given** the merged PR, **When** an operator reads
   `docs/local-devnet-smoke.md`, **Then** the bootstrap section
   describes the intent → `tx-build` operator path, identifies
   `SmokeSpec` as the library proof, and notes that the bash CLI
   smoke arrives in #161.

---

### Edge Cases

- A `bootstrap-intent.json` declaring a `network` other than DevNet
  must fail closed before any N2C connection or build step.
- A `bootstrap-intent.json` whose `action` discriminator names a
  known string but mismatches the payload shape (e.g.
  `"registry-init"` with a stake-reward payload) must fail at decode
  with a typed error.
- `encodeSomeTreasuryIntent` for an init variant must round-trip
  through `decodeTreasuryIntent` without losing or reordering
  significant fields (golden round-trip per action).
- The relocated runners must not be exposed as Hackage public modules
  that an external consumer could mistake for an operator path.
- Schema generators (`exe:amaru-treasury-intent-schema`) must include
  the three new variants and the committed
  `docs/assets/intent-schema.json` must stay in sync (`just
  schema-check` green).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `amaru-treasury-tx` MUST NOT expose a `devnet`
  subcommand, nor `registry-init`, `stake-reward-init`,
  `governance-withdrawal-init`, or `disburse-submit` as shipped CLI
  subcommands at any nesting level.
- **FR-002**: `Amaru.Treasury.IntentJSON.SomeTreasuryIntent` MUST
  gain three new constructors — one each for `registry-init`,
  `stake-reward-init`, and `governance-withdrawal-init` — with
  matching `Action` constructors, `SAction` witnesses, `Payload`
  family arms, and `Translated` family arms.
- **FR-003**: For each new init variant, `FromJSON` /
  `ToJSON` instances MUST satisfy the round-trip invariant
  `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right`.
- **FR-004**: `Cli/TxBuild.hs::runTxBuild` reading a
  `bootstrap-intent.json` for any of the three init actions MUST
  produce an unsigned tx CBOR hex byte-identical to the CBOR the
  corresponding `lib/Amaru/Treasury/Devnet/*Init.hs` library function
  builds for the same logical inputs (golden coverage per action).
- **FR-005**: `lib/Amaru/Treasury/Devnet/RegistryInit.hs`,
  `StakeRewardInit.hs`, `GovernanceWithdrawalInit.hs`, and
  `DisburseSubmit.hs` MUST remain consumable by
  `Amaru.Treasury.Devnet.SmokeSpec` as library functions and MUST
  NOT be reachable from the shipped CLI parser or any executable
  exposed by the cabal package.
- **FR-006**: Every CLI entry that previously delegated to a
  `runDevnet*` runner MUST be removed; the `Cmd` ADT,
  `devnetCmdP` subparser, and `Cli/Devnet.hs` module are removed
  with their direct dependents updated.
- **FR-007**: Any new entry that touches DevNet bootstrap behavior
  (intent decoders, `tx-build` dispatch arms) MUST fail closed for
  non-DevNet networks before any build or N2C effect.
- **FR-008**: `docs/assets/intent-schema.json` MUST include the
  three new variants; `just schema-check` MUST pass.
- **FR-009**: `README.md` and `docs/local-devnet-smoke.md` MUST
  describe the new operator path (`tx-build --intent <…>`), MUST
  remove references to the old `devnet <action>` invocation, and
  MUST forward-reference #158–#160 for the wizard producers and
  #161 for the bash smoke.
- **FR-010**: The PR MUST be bisect-safe — every commit MUST pass
  `./gate.sh`.

### Non-Functional Requirements

- **NFR-001**: The intent JSON envelope for the three init variants
  follows the same schema conventions as the existing
  `swap` / `disburse` / `withdraw` variants (`action`,
  `schemaVersion`, `network`, `payload`).
- **NFR-002**: No new public Hackage modules; relocated runners
  remain in `lib/Amaru/Treasury/Devnet/` and are exposed only
  insofar as `SmokeSpec` needs them.
- **NFR-003**: No DevNet-only code paths are introduced into shared
  modules that other operator commands import unconditionally.

### Key Entities

- **`Action`** — sum type indexed by `Action` kind via `-XDataKinds`;
  gains `RegistryInit`, `StakeRewardInit`, `GovernanceWithdrawalInit`.
- **`SomeTreasuryIntent`** — existential wrapper around the
  `Action`-indexed `TreasuryIntent`; gains constructors for the three
  init variants.
- **`runFromIntentEither`** — dispatcher in `Amaru.Treasury.Build`;
  gains arms for the three new `SAction` witnesses.
- **`runTxBuild`** — top-level intent driver in
  `Amaru.Treasury.Cli.TxBuild`; unchanged in shape but exercises the
  new dispatch arms via the new variants.
- **Relocated runners** — `runDevnetRegistryInit`,
  `runDevnetStakeRewardInit`, `runDevnetGovernanceWithdrawalInit`,
  `runDevnetDisburseSubmit` — kept under `lib/Amaru/Treasury/Devnet/`
  per parent #156's "library proof survives" invariant; consumed
  only by `SmokeSpec`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `amaru-treasury-tx --help` and
  `amaru-treasury-tx devnet …` show no `devnet`, `registry-init`,
  `stake-reward-init`, `governance-withdrawal-init`, or
  `disburse-submit` subcommand at any nesting level (parser test).
- **SC-002**: For each of the three init actions, a golden test
  asserts that `runTxBuild` on the bootstrap intent JSON produces
  CBOR bytes identical to the bytes produced by the corresponding
  library function for the same logical inputs.
- **SC-003**: Round-trip property:
  `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for
  each of the three init variants (unit / property test).
- **SC-004**: `nix build .#checks.unit`, `nix build .#checks.golden`,
  `just schema-check`, and `just format-check` / `just hlint` are
  green at every commit on the branch.
- **SC-005**: `SmokeSpec` builds and passes against `withDevnet`
  using only library function calls, no CLI shelling, no
  `devnet …` invocation.
- **SC-006**: PR body, README, and `docs/local-devnet-smoke.md`
  agree on the new operator path and on the location of the
  legacy runners (kept for `SmokeSpec`, no longer a CLI surface).

## Command-Recovery Posture

#157 changes the **shape** of the operator path for the three init
actions: the user-facing command after this PR is
`amaru-treasury-tx tx-build --intent <bootstrap-intent.json>`. The
producer of that JSON is intentionally **not** in scope — wizard
producers ship in #158–#160.

In particular:

- **Operator command (P1)**: `amaru-treasury-tx tx-build --intent
  <bootstrap-intent.json>`. Mainnet/preprod fail closed.
- **Library proof (P1)**: `Amaru.Treasury.Devnet.SmokeSpec`
  consumes the relocated library functions through `withDevnet`.
- **CLI proof (deferred)**: bash `smoke.sh` lives in #161.

This PR does NOT claim later child-ticket behavior:

- It does NOT introduce a `registry-init-wizard`,
  `stake-reward-init-wizard`, or
  `governance-withdrawal-init-wizard`. Those are #158–#160.
- It does NOT introduce `scripts/smoke/smoke.sh`. That is #161.
- It does NOT change mainnet or preprod semantics for any
  bootstrap action.

## Non-Goals

- New wizard commands. (`#158`, `#159`, `#160`.)
- Bash CLI-driven smoke. (`#161`.)
- Mainnet or preprod safety for the bootstrap actions.
- Replacing the disburse intent encoding (already shipped in
  `Amaru.Treasury.Tx.DisburseIntentJSON` via `Tx/DisburseIntentJSON.hs`).
- Promoting the relocated runners as Hackage-public modules.

## Parent Carry-Forward Invariants

From #156, every child carries these invariants; #157 implements the
first two and preserves the rest for downstream children:

- Shipped CLI bootstrap surface produces unsigned txs only;
  wizard → `tx-build` → unsigned CBOR; signing and submission stay
  on the separated `witness` / `attach-witness` / `submit` commands.
- Bootstrap transaction construction lives in production library code,
  not in `SmokeSpec` and not in CLI glue.
- DevNet end-to-end build+sign+submit+verify is a smoke concern, not a
  shipped surface; today's runners remain library functions consumed
  by `SmokeSpec` until #161.
- Two proof layers: `SmokeSpec` (library, retained here) and
  `smoke.sh` (CLI, deferred to #161).
- Network safety: every CLI bootstrap entry refuses non-DevNet
  networks (fail-closed).
