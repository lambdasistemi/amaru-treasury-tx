# Phase 0 Research: Swap Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file resolves the Technical Context unknowns flagged by
`/speckit.plan` and records design decisions whose rationale should
not be discovered later by reading the implementation. Each section
follows the *Decision / Rationale / Alternatives considered* format.

## R1. Where the typed answers live

**Decision**: New module `Amaru.Treasury.Tx.SwapWizard` exposes
`SwapWizardQ`, `WizardEnv`, `NetworkConstants`, and the pure
`wizardToIntentJSON :: WizardEnv -> SwapWizardQ -> SwapIntentJSON`.

**Rationale**:
- Keeps the existing `SwapIntentJSON` module focused on JSON parsing
  and translation to ledger types.
- Lets the golden test live entirely off the parser path.
- One file per "vertical slice" matches the existing
  `Tx/{Swap,Disburse,Withdraw,Reorganize}.hs` pattern.

**Alternatives considered**:
- Folding into `SwapIntentJSON.hs` — rejected; conflates "produce
  JSON" with "parse JSON".
- New package — rejected; one CLI subcommand is not worth a package
  boundary.

## R2. Pure vs. IO split

**Decision**:
- `SwapWizardQ` and `WizardEnv` are pure data.
- `wizardToIntentJSON :: WizardEnv -> SwapWizardQ -> SwapIntentJSON`
  is total and pure.
- Resolution (registry walk, UTxO selection, tip, slot math) lives in
  `resolveWizardEnv :: Provider IO -> ResolverInput -> IO WizardEnv`.
- Prompting lives in `runPromptLoop :: ResolvedDefaults -> IO SwapWizardQ`.
- The subcommand wires them: `Provider IO` → `resolveWizardEnv` →
  `runPromptLoop` → `wizardToIntentJSON` → write file.

**Rationale**: Constitution II (pure builders, impure shell) and
spec FR-010 (pure translation testable by golden).

**Alternatives considered**:
- `IO`-flavoured translation that reads from a `Reader` env —
  rejected; defeats golden testing without a stub backend.
- Embedding network constants in `WizardEnv` vs. selecting them from
  `ScopeId + NetworkId` at translation time — picked the latter so
  the table is part of the pure translation, not the resolver.

## R3. Provider IO surface used

**Decision**: The resolver depends only on these `Provider IO` queries:

1. `queryUTxOsAt :: Addr -> IO (Map TxIn Value)` — for treasury and
   wallet addresses.
2. `queryRegistry :: TxIn -> IO RegistryView` — chases the registry
   NFT to extract `*DeployedAt`, owner key hashes, treasury script
   hash, permissions reward account.
3. `queryTip :: IO SlotNo` — current chain tip for validity-window
   math.
4. `slotsPerHour :: IO Word64` (or a constant per network) — to
   convert the validity window in hours to a slot delta.

If `Provider IO` does not yet expose `queryRegistry`, the resolver
calls a thin helper in `lib/Amaru/Treasury/Backend/*` that walks the
chain via existing `Backend` ops. No new direct N2C dependency.

**Rationale**: Constitution III — no backend leakage into pure
modules; reuse what exists.

**Alternatives considered**:
- A new `RegistryClient` typeclass — rejected as premature; one
  pure helper over the existing `Provider IO` is enough for v1.
- Reading the registry NFT directly via Blockfrost — rejected; would
  introduce a second backend path.

**MVP scope deviation**: the v1 resolver does *not* walk the
registry NFT on-chain. Reading the inline datum of the registry
UTxO and chasing its references requires deep Plutus-data parsing
that does not belong in the wizard critical path. Instead the CLI
takes the `RegistryView` as a JSON file (e.g. `--registry
registry.json`); the operator produces it once per network and
re-uses it. The on-chain walk is recorded as out-of-scope and is
follow-up work tracked separately.

## R4. Treasury UTxO selection policy

**Decision**: Largest-first deterministic selection. Sort the address's
pure-ADA + USDM UTxOs by lovelace descending, accumulate until the
sum is ≥ total ADA needed for the swap. The leftover lovelace is
exactly `Σinputs − totalSwapAda`.

**Rationale**:
- Deterministic: same inputs → same selection → byte-identical CBOR
  for SC-003.
- Largest-first minimises the count of treasury UTxOs consumed,
  which keeps the chunk loop short and the leftover output simple.
- Easy to refute when wrong: an explicit `--utxos` override flag is
  cheap to add later if a scope needs to pin the selection.

**Alternatives considered**:
- Smallest-first ("clean-up old dust") — rejected; couples the
  wizard to a treasury-hygiene policy that should be a separate
  subcommand.
- Random / coin-selection algorithm — rejected; non-deterministic
  output breaks SC-003.

## R5. Wallet UTxO selection

**Decision**: Largest pure-ADA UTxO at the wallet address, regardless
of count. Errors out if no pure-ADA UTxO exists.

**Rationale**: The wallet UTxO is fuel + collateral; the swap
transaction only needs one input there, and "biggest spare UTxO" is
the standard default.

**Alternatives considered**:
- Wallet-side coin selection across multiple inputs — rejected;
  matches no real-world swap workflow and complicates the JSON
  schema (the existing intent assumes one `wallet.txIn`).

## R6. Validity window translation

**Decision**: The wizard asks the user for an integer number of hours
in the range [1, 48]. It multiplies by `slotsPerHour` (network
constant: 3600 on preprod/mainnet under 1-second slots) and adds the
result to the current tip. The sum is `validityUpperBoundSlot`.

**Rationale**: Hours map to operator intuition; the slot-conversion
is a network constant, not a moving protocol parameter.

**Alternatives considered**:
- Asking for a target slot directly — rejected; rejects the
  ergonomics goal (SC-001).
- Asking for a target wall-clock — rejected; introduces a
  timezone/format failure surface.

## R7. NetworkConstants table

**Decision**: Constant Haskell table, parameterised by `Network`
(matching the existing `Cardano.Ledger.BaseTypes.Network`). One row
per supported network with: `swapOrderAddress`, `usdmPolicy`,
`usdmToken`, `sundaeProtocolFeeLovelace`, `extraPerChunkLovelace`,
`slotsPerHour`, default `poolId`. Updating the table is a code change
+ PR; the wizard refuses to run on networks that have no row.

**Rationale**: These values change rarely and need code-review
discipline (legal/financial implications). A live query would be
strictly worse: harder to audit and a new failure surface.

**Alternatives considered**:
- TOML/JSON file shipped alongside the binary — rejected; same
  audit-trail problem, plus a new packaging concern.
- Live query against SundaeSwap/USDM — rejected for v1; revisit if
  the address ever changes outside a code release window.

## R8. Confirmation and `--yes` flag

**Decision**: The default mode prints every resolved field and the
answers, then asks `Confirm and write intent.json? [y/N]`. A `--yes`
flag bypasses the prompt for scripted use. A `--dry-run` flag prints
the JSON to stdout and skips the file write.

**Rationale**: FR-013 (log resolved fields) + FR-014 (require
explicit confirmation) + standard CLI hygiene for automation.

**Alternatives considered**:
- Always require confirmation — rejected; blocks scripted use.
- No confirmation by default — rejected; an operator could
  inadvertently overwrite a hand-curated `intent.json`.

## R9. Stable JSON encoder for golden tests

**Decision**: Use `aeson`'s `encodePretty` from
`aeson-pretty` with a fixed key-order list matching
`SwapIntentJSON`'s record order. Add a `Aeson.ToJSON SwapIntentJSON`
instance if missing, mirroring the existing `FromJSON` field names.

**Rationale**: Golden tests fail loudly on encoder churn. Pinning
key order to the `FromJSON` schema also documents the contract.

**Alternatives considered**:
- Plain `aeson.encode` with no pretty printing — rejected; key-order
  is unstable across `aeson` minor versions.
- Custom hand-rolled encoder — rejected; one more thing to maintain.

## R10. Testing strategy

**Decision**:
- **Unit / golden** (lands first): a single `SwapWizardSpec.hs` that
  loads a fixture `WizardEnv` + `SwapWizardQ` from
  `test/fixtures/swap-wizard/`, runs `wizardToIntentJSON`, and
  compares to a checked-in `expected.intent.json`.
- **Roundtrip property**: for any `SwapWizardQ` and any `WizardEnv`
  the output must satisfy `decodeSwapIntent (encode (toJSON …)) =
  Right …`, then `translateIntent` must succeed. Property uses a
  small generator over `SwapWizardQ` and a fixed `WizardEnv`.
- **End-to-end** (manual, recorded in quickstart): produce a JSON on
  preprod, hand it to `amaru-treasury-tx swap`, confirm the existing
  golden suite still passes byte-for-byte.

**Rationale**: Constitution V (test-first with golden CBOR
fixtures) and SC-002, SC-003.

**Alternatives considered**:
- Skip the property test and rely on the golden — rejected; one
  fixture is not enough to catch shape regressions.
- Add a new integration test that builds a real tx — rejected;
  overlap with the existing swap golden harness.
