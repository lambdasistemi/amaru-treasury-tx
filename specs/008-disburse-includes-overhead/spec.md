# Feature Specification: Disburse Amount Includes Swap-Order Overhead

**Feature Branch**: `008-disburse-includes-overhead`
**Created**: 2026-05-08
**Status**: Draft
**Input**: User description from issue [#68](https://github.com/lambdasistemi/amaru-treasury-tx/issues/68): swap-wizard's disburse redeemer should fund per-chunk swap-order overhead from the treasury, not the operator wallet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Treasury funds the swap-order overhead (Priority: P1)

A treasury operator runs `swap-wizard … --split N | tx-build` to disburse treasury funds into N SundaeSwap V3 chunked orders. Today, the operator's personal wallet has to fund `N × 3.28 ADA` of swap-order overhead (a 2 ADA min-UTxO deposit plus a 1.28 ADA Sundae protocol fee per chunk) on top of the network tx fee, while also providing the collateral UTxO required by the protocol. The operator wants the treasury to fund that overhead so the personal wallet only pays the network tx fee on success (collateral is a required available UTxO that returns intact when the transaction succeeds), since the funds being swapped originate from the treasury and the post-fill min-UTxO refund returns to the treasury anyway.

**Why this priority**: This is the entire reason the issue was filed. The current behavior makes operator wallets bleed roughly 39 ADA per 12-chunk swap and creates a real operational tax on the operator role. It is a single, self-contained change to the disburse-redeemer construction and unblocks larger or more frequent splits without operator-wallet pre-funding rituals.

**Independent Test**: Run a swap-wizard build with `--usdm <X> --split N` against the same inputs as the issue's captured example (`30af3b92…`, `--usdm 100000 --split 12`, mainnet) and verify the operator wallet's net spend on a successful transaction (defined as `wallet inputs − wallet change`, which excludes collateral since collateral inputs equal collateral outputs on success) drops from `N × 3.28 ADA + tx fee` to just `tx fee`, while the treasury leftover shrinks by exactly `N × 3.28 ADA` more than it does today.

**Acceptance Scenarios**:

1. **Given** treasury UTxO of 1,450,000 ADA and operator wallet of 100 ADA, **When** the operator runs `swap-wizard --usdm 100000 --split 12 | tx-build`, **Then** the operator wallet's net spend on success (`wallet inputs − wallet change`) is approximately the network tx fee (~0.64 ADA) — no per-chunk overhead — collateral inputs and outputs net to zero, and the treasury leftover is `1,005,555.555556 − 12 × 3.28 = 1,005,516.195556 ADA` (or equivalent).
2. **Given** any `--split N` value with `N ≥ 1`, **When** the disburse redeemer is constructed, **Then** the redeemer's `amount` equals `chunk_total + N × per_chunk_overhead`, where `per_chunk_overhead = extraPerChunkLovelace` taken from the swap intent (see FR-006). `extraPerChunkLovelace` is the single field that already carries the full per-chunk overhead (Sundae min-UTxO deposit + protocol fee, e.g. 3,280,000 lovelace in the current fixture).
3. **Given** the on-chain disburse validator at [`treasury-contracts/lib/logic/treasury/disburse.ak`](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/lib/logic/treasury/disburse.ak) using `equal_plus_min_ada`, **When** the new redeemer with the larger `amount` is submitted, **Then** the transaction validates and is accepted on-chain.

---

### User Story 2 - Bash swap recipes mirror the fix (Priority: P2)

The journal recipes under [`pragma-org/amaru-treasury` `journal/2026/bin/swap.sh`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026/bin) construct the same disburse-redeemer shape via shell. After the Haskell fix lands, the bash recipe should be updated so journal-driven swaps behave identically and there is no second source of the bug.

**Why this priority**: Lower priority because the journal is for documentation / hand-run experiments; the operator-facing CLI is the production path. But leaving the bash recipe unfixed will recreate the bug whenever someone copies it into a new journal entry, so it must follow shortly after.

**Independent Test**: Re-run a journal swap example via the bash recipe after the Haskell fix is merged and confirm operator-wallet net-out matches the swap-wizard / tx-build path.

**Acceptance Scenarios**:

1. **Given** the Haskell fix has merged, **When** the bash recipe at `journal/2026/bin/swap.sh` is invoked with the same `--usdm` / `--split` args, **Then** the resulting disburse redeemer's `amount` matches the one produced by the Haskell builder.

---

### Edge Cases

- **N = 1 (no split)**: The single-chunk path must apply the same `chunk_total + 1 × per_chunk_overhead` rule — there is no special-case skip.
- **Treasury under-funding**: If the treasury UTxO does not hold `chunk_total + N × per_chunk_overhead`, the build must fail at construction time with a clear "treasury cannot fund overhead" message rather than silently falling back to the operator wallet.
- **SundaeSwap fee schedule changes**: The 1.28 ADA Sundae protocol fee is set by the AMM. If it changes, the constants used here must be discoverable / updateable in one place.
- **Min-UTxO deposit drift**: If protocol parameters raise the min-UTxO threshold, the constant used in the disburse amount must track it, otherwise builds will start under-funding.
- **Permissions multisig (`Disburse` arm of `TreasurySpendRedeemer` in `permissions.ak`)**: The multisig signers approve a disbursement; today they do not appear to inspect `amount` magnitude. Increasing `amount` by overhead must not break that approval semantics — to be confirmed in research before planning.
- **Order-fill refund routing**: After a Sundae order fills, the 2 ADA min-UTxO returns to the treasury (not the operator). The fix relies on this — if any chunk fails, the refund path must remain to the treasury.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When constructing a multi-chunk swap-disbursement transaction, the system MUST set the disburse redeemer's `amount` to `chunk_total + N × per_chunk_overhead`, where `N` is the number of chunks and `per_chunk_overhead = extraPerChunkLovelace` taken from the swap intent (the authoritative source named in FR-006). `extraPerChunkLovelace` is the single field that already carries the full per-chunk overhead added to each swap-order output (currently 3,280,000 lovelace, comprising the Sundae min-UTxO deposit plus the Sundae V3 protocol fee); it MUST NOT be summed with `sundaeProtocolFeeLovelace` again.
- **FR-002**: The treasury leftover output produced by the build MUST shrink by exactly `N × per_chunk_overhead` compared to today's behavior, holding `chunk_total` constant.
- **FR-003**: On a successful transaction, the operator wallet's net spend, defined as `wallet inputs − wallet change`, MUST equal the network tx fee only — never per-chunk swap-order overhead. Collateral is a required available UTxO whose collateral inputs and collateral outputs net to zero on success and so do not appear in net spend; on a phase-2 script failure the protocol forfeits the collateral, but that is outside the success path this requirement covers.
- **FR-004**: The fix MUST apply uniformly for any split value `N ≥ 1`, including the single-chunk case.
- **FR-005**: The transaction produced MUST validate on-chain against the existing disburse validator (`equal_plus_min_ada` semantics in `treasury-contracts/lib/logic/treasury/disburse.ak`) without requiring contract changes.
- **FR-006**: There MUST be a single authoritative source for `per_chunk_overhead`: the `extraPerChunkLovelace` field already carried by the swap intent (see `lib/Amaru/Treasury/IntentJSON.hs`; the value flows into `siSwapOrderExtraLovelace` in `lib/Amaru/Treasury/Tx/Swap.hs`, which is documented as "Sundae protocol fee + min UTxO deposit"). All four computations — the redeemer `amount` (FR-001), the treasury input selection target, the treasury leftover output (FR-002), and the under-funding shortfall check (FR-009) — MUST derive `N × per_chunk_overhead` from that one field. The separate `sundaeProtocolFeeLovelace` field is the AMM fee that gets written into each Sundae order datum so the protocol knows what fee the order is paying; it MUST NOT be added to `extraPerChunkLovelace` for funding purposes. The implementation MUST NOT introduce a second hard-coded constant or a parallel calculation; a future SundaeSwap or protocol-parameter change is a one-line edit at the intent source.
- **FR-007**: Before implementation, the team MUST confirm whether the permissions multisig (`Disburse { .. }` arm of `TreasurySpendRedeemer` in `permissions.ak`) constrains `amount` magnitude beyond signer approval. If it does, the spec is reopened.
- **FR-008**: The bash swap recipe at `pragma-org/amaru-treasury` `journal/2026/bin/swap.sh` MUST be updated to mirror the fix once the Haskell change lands, so journal-driven swaps stay consistent with the CLI path; it MUST source the same `extraPerChunkLovelace` value from the swap intent rather than introducing a parallel constant.
- **FR-009**: If the treasury UTxO cannot fund `chunk_total + N × per_chunk_overhead` (using the authoritative source from FR-006), the build MUST fail at construction time with a clear error message identifying the shortfall.

### Key Entities

- **Disburse redeemer `amount`**: The lovelace value declared in the `Disburse { amount = ... }` redeemer arm consumed by the treasury validator. Today this equals the chunk_total; after the fix it equals `chunk_total + N × per_chunk_overhead`.
- **`per_chunk_overhead`**: The lovelace each Sundae V3 order needs in addition to the swapped funds. This equals `extraPerChunkLovelace` from the swap intent (see FR-006); that one field already aggregates the Sundae min-UTxO deposit and the Sundae V3 protocol fee. In the current network configuration the intent value is `3_280_000` lovelace (3.28 ADA = 2 ADA min-UTxO deposit + 1.28 ADA Sundae fee), but the spec is parameterised on the intent value, not the literal number. The separate `sundaeProtocolFeeLovelace` field is the AMM fee written into each order datum and is **not** added to this overhead.
- **Chunk**: One SundaeSwap V3 order output produced by the split. Each chunk consumes one `per_chunk_overhead` worth of lovelace on top of its share of `chunk_total`.
- **Treasury UTxO**: The treasury input being spent by the disburse transaction.
- **Treasury leftover**: The continuing-treasury output that holds whatever the treasury input had minus `amount`.
- **Operator wallet UTxO**: A wallet input contributing to the network tx fee and providing the collateral UTxO. After the fix it does not contribute to swap-order overhead.
- **Operator wallet net spend (success path)**: `wallet inputs − wallet change` summed over non-collateral UTxOs — i.e. the lovelace the wallet actually loses on a successful transaction. Collateral UTxOs are excluded because the collateral output equals the collateral input on success.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reproducing the issue's captured example (`--usdm 100000 --split 12`, mainnet, 1,450,000 ADA treasury UTxO + 100 ADA wallet UTxO) produces an operator wallet net spend on success (`wallet inputs − wallet change`) of less than 1 ADA (tx fee only), down from ~39.36 ADA today. Collateral is unaffected because collateral inputs and outputs net to zero on success.
- **SC-002**: For any `--split N`, the treasury leftover decreases by exactly `N × per_chunk_overhead` relative to today's build, and the operator wallet's net spend on success decreases by the same amount.
- **SC-003**: The transaction submitted by the new builder is accepted on-chain by the existing disburse validator without any contract redeployment.
- **SC-004**: The bash journal recipe and the Haskell CLI produce disburse redeemers whose `amount` fields agree byte-for-byte for the same inputs (including the same `extraPerChunkLovelace` from the swap intent).

## Assumptions

- The full per-chunk overhead (Sundae min-UTxO deposit + Sundae V3 protocol fee — currently 2 ADA + 1.28 ADA = 3.28 ADA in total) is supplied as the single `extraPerChunkLovelace` field in the swap intent and matches the values in effect on the target network at the time of build; if either component changes, the intent value tracks it.
- The separate `sundaeProtocolFeeLovelace` field in the swap intent (with the network default in `lib/Amaru/Treasury/Constants.hs`) is the AMM fee value written into each Sundae order datum so the protocol knows what fee the order is paying; it is intentionally distinct from the funding overhead in `extraPerChunkLovelace`.
- The disburse validator's `equal_plus_min_ada` check (`output_sum.lovelace >= (input_sum − amount).lovelace`) means that increasing `amount` only loosens the constraint on the leftover — it cannot cause previously-valid transactions to fail.
- The permissions multisig (`Disburse` arm of `TreasurySpendRedeemer` in `permissions.ak`) authorizes a disbursement based on signer approval and does not inspect `amount` magnitude. This is the expectation per the issue's analysis but must be verified during planning before any implementation begins.
- After a Sundae V3 order fills, the 2 ADA min-UTxO is returned to the treasury address rather than the operator wallet — the fix relies on this routing being correct in the order metadata already produced today.
- This change is purely a transaction-builder fix in `Tx.Swap` / `IntentJSON.mkChunks` — no on-chain contract changes, no new redeemer fields, no operator-wallet workflow changes beyond the reduced ADA outlay.
