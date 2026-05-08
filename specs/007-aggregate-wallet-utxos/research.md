# Research: Aggregate Wallet UTxOs as Fuel in swap-wizard

Phase 0 design notes. Each section captures a decision, the rationale, and alternatives considered.

## D1. Aggregate inside the wizard vs. require operator pre-consolidation

**Decision**: aggregate inside the wizard.

**Rationale**: operators are expected to keep wallets warm (fees, governance NFTs, USDM, LP tokens). Forcing them to run a consolidation tx before every swap is operational friction with no upside. The aggregation algorithm is pure, runs in the resolver, and is bounded by the number of UTxOs at the wallet address (typically <100 in practice).

**Alternatives**:

- **Operator pre-consolidates manually.** Status quo. Rejected: it's the bug we're fixing.
- **Wizard emits a multi-tx plan (consolidate + swap).** Rejected: violates the "one intent → one tx" contract of the unified `TreasuryIntent` schema. Multi-tx orchestration belongs in a different tool.
- **Builder aggregates at balance time.** Rejected: the builder receives a `SwapIntent` with explicit inputs; introducing implicit input scavenging at balance time would break the spec's "intent.json is a complete description of the tx" property and would make the wallet target hard to surface up to the operator.

## D2. Wallet target formula

**Decision**: `walletTarget = chunkCount × ncExtraPerChunkLovelace + walletFeeSlackLovelace` with `walletFeeSlackLovelace = 2_000_000` (2 ADA).

**Rationale**: under current semantics (this feature does *not* fix issue #64), the operator wallet must front the per-chunk SundaeSwap deposits because the wizard's `selectTreasury` only sizes the leftover treasury output to absorb the swap target, not the deposits. Slack covers (a) the on-chain tx fee — empirically <1 ADA on a 10-chunk Conway tx with refs and ~5 script witnesses — and (b) the wallet change output's min-UTxO requirement (≈0.85 ADA for a pure-ADA output). 2 ADA leaves headroom for fee variance across protocol-parameter updates.

**Alternatives**:

- **`chunkCount × extraPerChunkLovelace` exactly, no slack.** Rejected: any fee > leftover lovelace makes balance fail. The point of this feature is to stop the silent-fail mode.
- **Operator-supplied slack via CLI flag.** Rejected: pushes a wizard-internal accounting concern onto every operator invocation. The current 2 ADA constant can be revisited if mainnet fee inflation makes it tight; bumping a constant is a one-line change.
- **Empirical slack derived from a fee-estimation pre-pass.** Rejected: the resolver runs before the typed builder constructs a tx body, so there's no candidate body to estimate against at this point. A pre-pass would require hoisting fee estimation into the resolver, creating a layering inversion.
- **Account for the SundaeSwap reclaim**: the deposit ~2 ADA per chunk is refunded by the matchmaker in a later tx (see `journal/ledger.md:117`). We don't credit this against the wallet target because reclaim happens *after* this tx settles — at intent-build time the wallet still has to lock the full deposit.

## D3. Collateral selection within the aggregated set

**Decision**: largest pure-ADA UTxO (the head of the largest-first sort) doubles as collateral. Extras are inputs only.

**Rationale**: collateral semantics on Conway require a single pure-ADA UTxO whose ADA covers `totalCollateral` (computed from the script execution budgets). The largest-first head is the safest pick. Today's `swapProgram` already does `collateral (siWalletUtxo si)` on the single-UTxO; the new aggregation simply reuses that input as collateral and adds the rest as plain spend inputs.

**Alternatives**:

- **Pick a different UTxO for collateral than for fuel.** Rejected: would mean keeping a separate non-fuel collateral UTxO in the wallet selection, doubling the wallet's pure-ADA UTxO count requirement. Operationally onerous.
- **Use Conway's `totalCollateral` + `collateralReturn` to size collateral exactly to budget.** Out of scope here — that's a cardano-node-clients concern; the existing `runSwap` path already wires `totalCollateralTxBodyL` correctly via the typed `TxBuild` DSL.

## D4. JSON shape: optional `extraTxIns` field with default `[]`

**Decision**: add `wallet.extraTxIns: array<TxIn>` to the unified `WalletJSON` shape. Always emitted on write (canonical empty list when empty); optional on read with `.!= []` default. No `tiSchema` bump.

**Rationale**: the change is strictly additive. A pre-feature reader that ignores unknown fields stays compatible; a pre-feature writer that omits `extraTxIns` is decoded by the new reader as `[]`. Backward and forward compatibility hold for the round trip `oldWriter → newReader` and `newWriter → oldReader` (the latter loses extras silently if those bytes are passed back to a stale builder, but we don't ship stale builders alongside new wizards in practice).

**Alternatives**:

- **Bump `tiSchema` to 2.** Rejected: tiSchema bumps mean every consumer rebuilds. The change here doesn't break the v1 contract — it only extends it.
- **Encode the wallet as a JSON array of TxIns directly (`wallet.txIns: [...]`).** Rejected: breaks the existing wire shape and forces a tiSchema bump. Loses the head-is-collateral cue carried by the current `txIn` field name.
- **Omit `extraTxIns` when empty (compact encoding).** Rejected: introduces nondeterminism in the canonical bytes the wizard emits; trips any consumer that relies on `extraTxIns` always being present (such as JSON-Schema's `required` list, were we to add it). Keeping the field always-present makes round-tripping deterministic.

## D5. Native-asset filter retained

**Decision**: keep the existing filter that excludes any wallet UTxO carrying native assets from the fuel-selection pool.

**Rationale**: spending an asset-bearing UTxO routes those assets somewhere — either to the leftover treasury output, to the wallet change output, or to a swap order. Each placement has a different security/legality story (do we accidentally pay USDM into a treasury that wasn't asked to receive it?). Outside the scope of this feature.

**Alternatives**:

- **Allow asset-bearing UTxOs and route their assets into the wallet change output.** Plausible, but requires extending `balanceTx`'s value-conservation handling and the wallet change output's `MultiAsset` shape. Tracked as a future change.

## D6. Failure modes

**Decision**: introduce `ResolverWalletShortfall !Integer !Integer` (available, requested) as a new constructor of `ResolverError`. Surfaces to the CLI via the existing `WeAborted` trace event and the existing `exit 3` path; no exception propagation.

**Rationale**: matches the symmetry of `ResolverShortfall` (treasury) and lets the CLI render a uniform shortfall message regardless of which side of the balance failed. The "wallet has zero pure-ADA UTxOs" sub-case continues to surface via `ResolverEmptyWalletUtxos` (kept distinct because it's actionable differently — "fund the wallet" vs. "fund more").

**Alternatives**:

- **Reuse `ResolverShortfall` for both treasury and wallet.** Rejected: loses the distinction at the CLI level.
- **Throw a Haskell exception with the new shape.** Rejected: violates the resolver's typed-error contract; every existing failure path is `Either ResolverError WizardEnv`.

## D7. Tracing the aggregated selection

**Decision**: extend `WeWalletUtxoSelected :: Text -> WizardEvent` to `WeWalletUtxoSelected :: Text -> [Text] -> WizardEvent` (head + extras) — a single-field breaking change to the event type, paid down across all callers in this commit.

**Rationale**: the trace is wizard-internal and not part of the JSON contract. Any external consumer scraping the human-readable wizard log keys off the message text, not the constructor shape.

**Alternatives**:

- **Add a sibling `WeWalletExtraInputsSelected [Text]` event.** Rejected: bifurcates the "what fuel was picked" log line. Operators reading the log shouldn't have to correlate two separate events.
