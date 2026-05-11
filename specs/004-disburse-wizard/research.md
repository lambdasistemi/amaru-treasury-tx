# Phase 0 Research: Disburse Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file resolves the Technical Context unknowns flagged by
`/speckit.plan` and records design decisions whose rationale should
not be discovered later by reading the implementation. Each section
follows the *Decision / Rationale / Alternatives considered* format.

**Post-#52 update**: PR
[#52](https://github.com/lambdasistemi/amaru-treasury-tx/pull/52)
landed the unified `TreasuryIntent` contract and `tx-build`
dispatcher before feature 004 completed. Feature 004 now emits
`TreasuryIntent 'Disburse` with top-level `schema` and `action`, and
the per-action `DisburseIntentJSON` / `DisburseBuild` modules are
legacy compatibility during the branch transition rather than the
operator-facing contract.

## R1. Module boundary — five new modules, one extension

**Decision**:

- **Extend** `Amaru.Treasury.Tx.Disburse` to add `disburseUsdmProgram`
  alongside the existing `disburseAdaProgram`.
- **Legacy compatibility** `Amaru.Treasury.Tx.DisburseIntentJSON` —
  the branch originally introduced this sibling record; after #52,
  new wizard output and body-CBOR goldens use
  `Amaru.Treasury.IntentJSON.TreasuryIntent 'Disburse`.
- **Legacy compatibility** `Amaru.Treasury.Tx.DisburseBuild` —
  the unified dispatcher now owns the real build entry point as
  `Amaru.Treasury.Build.runDisburse`.
- **New** `Amaru.Treasury.Tx.DisburseWizard` — `DisburseAnswers` ADT,
  `DisburseEnv`, `disburseToTreasuryIntent :: DisburseEnv ->
  DisburseAnswers -> Either DisburseError (TreasuryIntent 'Disburse)`
  (pure),
  plus `resolveDisburseEnv :: ResolverEnv IO -> ResolverInput -> IO
  (Either DisburseError DisburseEnv)`.
- **New** `Amaru.Treasury.Tx.Disburse.Trace` and
  `Amaru.Treasury.Tx.DisburseWizard.Trace` for typed `Tracer`-based
  events, mirroring
  [`Tx.Swap.Trace`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Swap/Trace.hs)
  and
  [`Tx.SwapWizard.Trace`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs).

**Rationale**:

- One module per "layer" matches the swap-wizard split. Each layer
  has a distinct testable contract: pure translation
  (`disburseToTreasuryIntent`), unified schema conformance
  (`decodeTreasuryIntent` + JSON Schema), IO build (`runDisburse`).
- Keeping the existing `Tx/Disburse.hs` as the home of pure
  `TxBuild q e ()` programs reuses the proven pattern from feature 002.
- Trace modules live next to their owners so `Trace` types can be
  internal to the layer that emits them.

**Alternatives considered**:

- **Folding into one module** — rejected; conflates JSON parsing,
  pure translation, and IO build, defeating layered tests.
- **A new `disburse` package or sublibrary** — rejected; one CLI
  subcommand pair is not worth a package boundary, same conclusion as
  R1 of feature 002.

## R2. Pure vs IO split

**Decision**:

- `DisburseAnswers`, `DisburseEnv`, `TreasuryIntent 'Disburse`, and
  `DisburseIntent` are pure data.
- `disburseToTreasuryIntent` is total and pure
  (`Either DisburseError (TreasuryIntent 'Disburse)`).
- `decodeTreasuryIntent` and `translateIntent SDisburse` are pure
  (`Either String _`).
- `disburseAdaProgram` and `disburseUsdmProgram` are pure
  `TxBuild q e ()`.
- IO is confined to `resolveDisburseEnv` (`Provider IO` calls,
  registry verify), `runDisburse` / `runFromIntent` (UTxO query,
  ExUnits eval,
  balance), and `app/Main.hs` (file I/O, tracer plumbing).

**Rationale**: Constitution II (pure builders, impure shell) and FR-008
(pure translation testable by golden).

**Alternatives considered**:

- **`IO`-flavoured translation reading from a Reader env** — rejected
  for the same reason as feature 002 R2: defeats golden testing
  without a stub backend.
- **Inlining `runSwapBuild`'s body into `runDisburse`** — picked
  the copy over an abstraction, since the build pipelines diverge in
  the redeemer set, the validator references, the output shape, and
  the required-signers list. Premature abstraction would force every
  future variant to fit one shape; the swap and disburse pipelines
  already disagree on enough that one shared pipeline would leak its
  specialisations through type parameters.

## R3. Provider IO surface used (resolver)

**Decision**: The wizard resolver `resolveDisburseEnv` depends only
on these `Provider IO` operations (already used by the swap wizard,
no new surface area):

1. `queryUTxOs :: Addr -> IO [(TxIn, TxOut)]` — for both wallet and
   treasury addresses.
2. `nowTip :: IO SlotNo` — current chain tip.
3. `posixMsToSlot :: Word64 -> IO SlotNo` — wall-clock-to-slot for
   validity-window math.

The verified registry is consumed via the existing
[`verifyRegistry`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Registry/Verify.hs)
+ `registryViewFromVerified` pipeline (same call site as the swap
wizard). No new on-chain query is introduced.

**Rationale**: Constitution III — no backend leakage into pure
modules; reuse what exists. Symmetry with feature 002 keeps the
`Backend` typeclass surface stable.

**Alternatives considered**:

- **A new `RegistryReader`-style typeclass** — rejected; one resolver
  helper over `Provider IO` is enough.
- **A blockfrost-backed resolver path** — out of scope for this
  feature; tracked under [#7](https://github.com/lambdasistemi/amaru-treasury-tx/issues/7).

## R4. Treasury UTxO selection — ADA vs USDM

**Decision**:

- **`--unit ada`**: largest-first deterministic selection over the
  scope's pure-ADA + USDM treasury UTxOs sorted by lovelace
  descending; accumulate until `Σlovelace ≥ amount + min-ADA-on-leftover`.
- **`--unit usdm`**: largest-first deterministic selection sorted by
  USDM quantity descending; accumulate until `Σusdm ≥ amount`. The
  selected inputs are also the ADA source for fees + the beneficiary
  output's min-ADA allowance + the leftover's min-ADA + assets.
- The leftover output is exactly `Σinputs − beneficiary` for every
  asset that appears on inputs (lovelace, USDM, others).

**Rationale**:

- Deterministic: same inputs → same selection → byte-identical CBOR
  for the goldens (SC-003 of feature 002 carries over).
- Largest-first minimises the count of treasury UTxOs consumed, which
  keeps the leftover-output asset map small.
- The two modes have distinct sort keys, but the selection algorithm
  is the same shape — easy to share a `selectByKey` helper.

**Alternatives considered**:

- **Smallest-first ("clean-up old dust")** — rejected; that is the
  job of the `reorganize` action (feature 006).
- **Random / coin-selection algorithm** — rejected; non-deterministic
  output breaks the byte-match goldens.

## R5. Wallet UTxO selection

**Decision**: Largest pure-ADA UTxO at the wallet address. Errors out
if no pure-ADA UTxO exists. Identical to feature 002 R5.

**Rationale**: The wallet UTxO is fuel + collateral; one input
suffices. Reusing the swap wizard's policy keeps the operator's
mental model consistent across actions.

**Alternatives considered**:

- **Multiple-input wallet coin selection** — rejected; same reasoning
  as feature 002 R5.

## R6. Validity window translation

**Decision**: Operator answer is `--validity-hours` in the range
[1, 48]. The wizard reads the current tip, converts the answer to a
slot delta via `slotsPerHour` (1-second slots on
preprod/mainnet/preview), and adds it to the tip. The result is
`validityUpperBoundSlot` in the JSON intent.

**Rationale**: Same as feature 002 R6. Hours map to operator
intuition; the slot conversion is a network constant.

**Alternatives considered**: Same as feature 002 R6.

## R7. NetworkConstants reuse

**Decision**: Reuse the existing
[`NetworkConstants`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs)
table from `Tx.SwapWizard` for `usdmPolicy`, `usdmToken`, and
`slotsPerHour`. Disburse does not depend on `swapOrderAddress`,
`sundaeProtocolFeeLovelace`, or `extraPerChunkLovelace` — those rows
are simply unused on this code path.

If the table moves into a shared module (e.g. `Amaru.Treasury.Network`)
that is a refactor tracked separately; for v0 the disburse wizard
imports the table from `Tx.SwapWizard` directly. A note on this
borrow goes into `data-model.md`.

**Rationale**: Avoid duplicating values that change for legal /
financial reasons (same audit-trail logic as feature 002 R7).

**Alternatives considered**:

- **Inline the constants in `DisburseWizard.hs`** — rejected; would
  drift from the swap wizard's view of the same network.
- **Extract a shared `Network` module now** — deferred; the borrow is
  acceptable until a third caller appears.

## R8. CLI shape — flags-only, no interactive prompts

**Decision**: Both subcommands use `optparse-applicative` with all
inputs supplied as flags, mirroring the `swap-wizard` CLI shape (no
interactive prompts, no `--yes`/`--dry-run` confirmation step). The
operator gets typed-trace lines on stderr (or `--log <path>`) instead
of an interactive review.

**Rationale**: The swap wizard already chose flags-only after
confirming the prompt-loop shape was unnecessary in practice. Disburse
follows the same path; symmetry is more valuable than a feature
inconsistency between `swap-wizard` and `disburse-wizard`.

**Alternatives considered**:

- **Re-introduce a confirmation prompt** — rejected; the wizard logs
  every resolved field via `DisburseWizardEvent`, which is enough for
  audit.
- **Read answers from a JSON file via `--answers`** — out of scope for
  v0; the flag set is small enough.

## R9. Stable JSON encoder for goldens

**Decision**: Reuse the unified `encodeSomeTreasuryIntent` stable
encoder introduced by #52 (four-space indent, alphabetical key order,
terminal newline). The checked-in disburse wizard goldens and the
ADA body-CBOR fixture intent both use this shape.

**Rationale**: Goldens fail loudly on encoder churn. Pinning the key
order to the `FromJSON` schema documents the contract.

**Alternatives considered**:

- **Plain `aeson.encode`** — rejected; key order unstable across
  `aeson` minor versions.

## R10. Testing strategy

**Decision**:

- **Unit / golden — pure translation** (lands first, red-failing): a
  single `DisburseSpec.hs` that loads fixture
  `(DisburseEnv, DisburseAnswers)` pairs from
  `test/fixtures/disburse-wizard/` for both ADA and USDM, runs
  `disburseToTreasuryIntent`, encodes via `encodeSomeTreasuryIntent`,
  and compares to checked-in
  `expected.intent.{ada,usdm}.json`.
- **Schema conformance**: checked-in disburse fixture JSON and JSON
  emitted by `disburseToTreasuryIntent` must validate against
  `docs/assets/intent-schema.json`.
- **Body-CBOR golden — ADA** (lands red before `disburseAdaProgram`
  changes): `DisburseSpec.hs` under `test/golden/Amaru/Treasury/Tx/`,
  fixture set under `test/fixtures/disburse/ada/`, recorded once
  against the local mainnet socket
  (`/code/cardano-mainnet/ipc/node.socket`), ExUnits stripped before
  compare.
- **Body-CBOR golden — USDM** (mirrors the ADA golden) under
  `test/golden/Amaru/Treasury/Tx/UsdmDisburseSpec.hs`, fixtures under
  `test/fixtures/disburse/usdm/`.
- **End-to-end smoke** (manual, recorded in quickstart): build a
  disburse against preprod, hand-sign offline, submit, observe;
  defers to a separate spec.

**Rationale**: Constitution V (test-first with golden CBOR fixtures,
NON-NEGOTIABLE) and SC-003/SC-004.

**Alternatives considered**:

- **Skip the round-trip property** — rejected; one fixture pair per
  unit is not enough to catch shape regressions in the JSON contract.
- **Synthesize the body-CBOR fixtures from a stub backend** —
  rejected; loses coverage of the ledger-API balancing path.

## R11. Reusing `runFromIntent`'s ChainContext

**Decision**: the unified `runDisburse` branch accepts a
[`ChainContext`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/ChainContext.hs)
the same way `runSwap` does. The required-utxo set passed to
`liveContext` is `walletUtxo : treasuryUtxos ++ [scopesDeployedAt,
permissionsDeployedAt, treasuryDeployedAt, registryDeployedAt]`.

**Rationale**: Identical lifecycle to swap; the `ChainContext`
abstraction was designed to be reused per action.

**Alternatives considered**: None — this is a direct mirror.

## R12. Required signers

**Decision**: Required signers = `[scopeOwner ++ extraSigners]`.

- `scopeOwner` is the keyhash of the scope being charged (always
  required, derived by the wizard from the verified registry; never
  passed by the operator).
- Extra signers come from `--extra-signer`/`--signer`, accepted
  either as a 28-byte hex keyhash or as the lowercased name of one of
  the four other scopes (`core_development | ops_and_use_cases |
  network_compliance | middleware`). Scope names resolve via the
  verified registry.

**Rationale**: Mirrors feature 002 PR
[#37](https://github.com/lambdasistemi/amaru-treasury-tx/pull/37) /
commit
[78366ff](https://github.com/lambdasistemi/amaru-treasury-tx/commit/78366ff)
("infer swap-wizard scope owner signer"); operators were dropping the
scope owner from their signer list and producing un-submittable txs.

**Alternatives considered**:

- **Take all signers explicitly** — rejected; matches the bug we
  already fixed for swap.

## R13. Intent JSON shape — unified TreasuryIntent

**Decision**: The earlier sibling-record decision is superseded by
[#51](https://github.com/lambdasistemi/amaru-treasury-tx/issues/51)
and [#52](https://github.com/lambdasistemi/amaru-treasury-tx/pull/52).
Feature 004 emits the unified shape:

- top-level `schema = 1`
- top-level `action = "disburse"`
- shared `network`, `wallet`, `scope`, `signers`,
  `validityUpperBoundSlot`, and `rationale`
- action-keyed `disburse` payload with `unit`, `amount`,
  `beneficiaryAddress`, `usdmPolicy`, and `usdmToken`

**Rationale**: The unified dispatcher removes the per-action builder
subcommands (`swap`, `disburse`, …) and lets every wizard pipe into the
same `tx-build` entry point. The JSON Schema can reject
action/payload mismatches centrally, while the typed
`TreasuryIntent a` GADT keeps action-specific payloads separated in
Haskell.

**Alternatives considered**:

- **Keep the original sibling `DisburseIntentJSON` as the public
  contract** — rejected after #52; it would fork the operator UX away
  from `swap-wizard | tx-build` and leave withdraw/reorganize to solve
  the same dispatch problem again.
- **Add a per-action `disburse` subcommand on top of `tx-build`** —
  rejected; it would duplicate parsing, network-probe, required-UTxO,
  and tracing logic that #52 deliberately centralized.
