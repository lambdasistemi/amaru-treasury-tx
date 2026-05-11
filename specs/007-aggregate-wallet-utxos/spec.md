# Feature Specification: Aggregate Multiple Wallet UTxOs as Fuel in swap-wizard

**Feature Branch**: `007-aggregate-wallet-utxos`
**Created**: 2026-05-08
**Status**: Draft
**Input**: User description: "Aggregate multiple wallet UTxOs as fuel in swap-wizard so the operator wallet can provide fee/change slack without a single fat pure-ADA UTxO. Largest-first pure-ADA aggregation until sum >= walletTarget where walletTarget = walletFeeSlackLovelace. Out of scope: disburse/withdraw/reorganize wizards. Backwards-compatible JSON shape via optional extraTxIns field default []. New ResolverWalletShortfall error replacing the silent fall-through to InsufficientFee."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator funds a swap from a wallet with multiple small UTxOs (Priority: P1)

A treasury operator wants to execute a SundaeSwap order out of a treasury scope. The on-chain operator wallet that authorizes the action holds its ADA across several small pure-ADA UTxOs (for example, three UTxOs of 1.2 ADA, 0.7 ADA, 0.3 ADA), none of which alone covers the fee/change slack target. Today the operator must first consolidate those UTxOs into one larger UTxO via a separate transaction. After this feature, the operator can run the swap pipeline directly: the wizard aggregates the smallest set of largest-first pure-ADA UTxOs that covers the slack target, and the builder spends them all.

**Why this priority**: this is the feature's core value. Without it, every operator with an organically-grown wallet has to perform a pre-step that has nothing to do with the swap itself.

**Independent Test**: pipe `swap-wizard` into `tx-build` against a wallet whose total pure-ADA balance covers the fee/change slack target but whose largest single UTxO does not. Today's behavior: the builder can die with `BalanceFailed (InsufficientFee ...)` and an uncaught Haskell exception. New behavior: an unsigned Conway tx in CBOR hex is emitted on stdout, with body inputs containing every selected wallet UTxO and the largest one as collateral.

**Acceptance Scenarios**:

1. **Given** an operator wallet with three pure-ADA UTxOs of 1.2 / 0.7 / 0.3 ADA (total 2.2 ADA) and a swap whose treasury input covers the swap amount plus per-chunk overhead, **when** the operator runs the swap-wizard → tx-build pipe, **then** the wizard emits an intent.json whose `wallet.txIn` is the 1.2 ADA UTxO and `wallet.extraTxIns` is `[0.7 ADA UTxO, 0.3 ADA UTxO]`, and the builder produces an unsigned Conway tx that spends all three.
2. **Given** an operator wallet with one pure-ADA UTxO of 50 ADA, **when** the operator runs the same pipe, **then** the wizard emits an intent.json with `wallet.txIn` set and `wallet.extraTxIns` set to `[]` — identical in shape to a pre-feature intent.

---

### User Story 2 — Operator gets a clear shortfall error before the builder runs (Priority: P2)

A treasury operator runs the swap-wizard against a wallet that doesn't actually have enough pure-ADA to cover the fee/change slack target. Today this can surface as `BalanceFailed (InsufficientFee ...)` from the builder with no operator-level context. After this feature the wizard refuses to emit an intent.json and instead reports a typed shortfall error stating the wallet address, the pure-ADA available, and the pure-ADA required. The pipe never reaches `tx-build`.

**Why this priority**: turns the hardest-to-diagnose failure mode into a single-line error. Independent of P1 in the sense that it can ship even if the aggregator chose the same single-UTxO behavior as today, but most useful in combination with P1.

**Independent Test**: run the swap-wizard against a wallet with 1 ADA total pure-ADA. Verify the wizard exits non-zero before any tx-build invocation, and stderr contains `wallet shortfall` along with the wallet address, the available pure-ADA total in lovelace, and the required total.

**Acceptance Scenarios**:

1. **Given** a wallet with total pure-ADA of 1 ADA and a swap request whose treasury can cover amount plus per-chunk overhead, **when** the wizard runs, **then** it exits non-zero, prints a single-line error naming the wallet address, the 1 ADA available, the 2 ADA required, and does not emit any intent.json bytes on stdout.
2. **Given** a wallet whose UTxOs are all NFT-bearing (no pure-ADA UTxOs), **when** the wizard runs, **then** it exits non-zero with the same shortfall error reporting 0 ADA available — without crashing on the empty selection.

---

### User Story 3 — Existing intent.json files keep working (Priority: P3)

An integrator (or operator) stored a pre-feature intent.json on disk and feeds it to a post-feature `tx-build`. The new wallet schema field is optional. The builder reads the file unchanged and spends the single wallet UTxO exactly as before.

**Why this priority**: prevents a silent breaking change for anyone shelving intents between the wizard and the builder. Lower priority because in practice the wizard and builder are run together via a pipe, not independently across versions.

**Independent Test**: take any of the checked-in fixtures under `test/fixtures/swap/` and `test/fixtures/swap-wizard/`, leave them unmodified (no `extraTxIns` field), and run the unit + golden tests. They pass without re-recording golden bytes.

**Acceptance Scenarios**:

1. **Given** the existing `test/fixtures/swap/intent.json` (no `extraTxIns` key), **when** decoded by the post-feature builder, **then** the `SwapIntent` value has `siExtraWalletInputs = []` and the resulting tx is byte-identical to today's output.
2. **Given** an intent.json round-tripped through the post-feature ToJSON / FromJSON, **when** the resulting bytes are validated against the JSON Schema asset, **then** validation passes whether or not `extraTxIns` is present.

---

### Edge Cases

- **Native-asset UTxOs in the wallet**: stay excluded from the selection pool. A wallet whose largest holdings are governance NFTs, USDM, or LP tokens still surfaces only its pure-ADA UTxOs.
- **Single UTxO covers target**: aggregation degenerates to today's behavior — head is the largest pure-ADA UTxO, `extraTxIns = []`, selection terminates after the first UTxO.
- **Total pure-ADA exactly equals target**: selection succeeds, the change output may be smaller than the operator expects but the builder respects the protocol min-UTxO check downstream.
- **Total pure-ADA equals target − 1 lovelace**: selection fails with `ResolverWalletShortfall available=target-1 requested=target`.
- **Wallet has zero UTxOs at all**: existing `ResolverEmptyWalletUtxos` error continues to fire (out of scope to merge with shortfall).
- **Wallet has dozens of dust UTxOs whose sum covers target**: every selected UTxO is added to the body's input set; collateral remains the head (largest); builder succeeds. Plutus phase-1 limits on input count are not expected to bind for any realistic operator wallet.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The wizard MUST select one or more pure-ADA wallet UTxOs as fuel by sorting available pure-ADA UTxOs largest-first and accumulating until the running sum covers the wallet target.
- **FR-002**: The wallet target MUST equal `walletFeeSlackLovelace = 2 ADA`. The treasury target, not the wallet target, covers `chunkCount × extraPerChunkLovelace`.
- **FR-003**: The wizard MUST exclude any wallet UTxO carrying native assets from the selection pool.
- **FR-004**: When the sum of pure-ADA wallet UTxOs is strictly less than the wallet target, the wizard MUST fail with a typed `ResolverWalletShortfall` error reporting the available pure-ADA total and the required wallet target, and MUST NOT emit an intent.json on stdout.
- **FR-005**: The emitted intent.json MUST encode the largest selected UTxO under `wallet.txIn` and any additional UTxOs under a new array field `wallet.extraTxIns`. The field is always present in newly-emitted intent.json (canonical empty list when there are no extras).
- **FR-006**: The builder's intent.json reader MUST accept intent.json files that omit `wallet.extraTxIns`, treating it as the empty list. Files written by previous tool versions MUST round-trip through the new builder without semantic change.
- **FR-007**: The builder MUST spend every UTxO listed under `wallet.extraTxIns` in addition to `wallet.txIn`, and MUST use only `wallet.txIn` as collateral.
- **FR-008**: The published JSON Schema asset MUST validate intent.json files both with and without a non-empty `wallet.extraTxIns` field.

### Key Entities

- **WalletSelection**: a non-empty ordered list of pure-ADA operator-wallet UTxOs. The head functions as both fuel and collateral; the tail are additional fuel inputs. Stored in the wizard env and projected into the intent.json's `wallet` block.
- **WalletJSON (intent.json shape)**: the wallet block carried by the unified `TreasuryIntent` envelope. Today carries `{ txIn, address }`; gains a third optional field `extraTxIns: [TxIn]` defaulting to `[]`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with three pure-ADA UTxOs (1.2 / 0.7 / 0.3 ADA) can complete a swap end-to-end (`swap-wizard | tx-build` pipe) without a pre-consolidation transaction. Today this fails; after this feature it produces an unsigned Conway tx CBOR.
- **SC-002**: When the wallet's pure-ADA total is below the wallet target, the operator sees a single error line on stderr naming both available and required figures and the wallet address, with the wizard exiting non-zero before any tx-build invocation. The previous opaque `BalanceFailed (InsufficientFee ...)` Haskell exception trace never appears for this failure mode.
- **SC-003**: Every checked-in intent.json fixture under `test/fixtures/swap/` and `test/fixtures/swap-wizard/` passes the post-feature unit + golden + JSON-schema tests without modification, demonstrating backward-compatible reads.
- **SC-004**: New unit tests cover, at minimum: aggregation across two UTxOs, single-UTxO degenerate case, native-asset exclusion, exact-shortfall boundary, JSON round-trip with non-empty extras, and a swap-program test asserting the body's input set contains every selected UTxO with collateral set to the head.

## Assumptions

- **Out of scope: disburse, withdraw, and reorganize wizards.** Their fuel-selection paths haven't converged on `selectWallet`. Migrating them is a separate follow-up; the three intent variants continue to use a single wallet UTxO for now.
- **Issue #64 treasury funding has landed.** The treasury self-funds per-chunk SundaeSwap overhead. The wallet target is therefore `walletFeeSlackLovelace` only; the aggregation algorithm and JSON shape are unchanged.
- **2 ADA fee slack is enough.** Typical Conway-era swap transactions (treasury inputs + multiple swap-order outputs + leftover output + reference inputs + script witnesses) settle below 1.5 ADA in fees on mainnet. 2 ADA slack absorbs the fee plus the wallet change output's min-UTxO requirement.
- **Native-asset wallet UTxOs stay excluded** from the selection pool, consistent with today's behavior. Relaxing this (so the operator can spend an asset-bearing UTxO and route the assets into the leftover treasury output) is a future change with a different risk profile.
- **The treasury owns the order overhead lifecycle.** SundaeSwap V3's order validator routes residual ADA (~2 ADA per chunk) to the destination encoded in the order datum, which is the treasury script address. The operator wallet does not front this value.
