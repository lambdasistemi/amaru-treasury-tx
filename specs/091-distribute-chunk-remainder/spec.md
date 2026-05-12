# Feature Specification: Distribute swap-order remainder; eliminate dust outputs

**Feature Branch**: `feat/091-distribute-chunk-remainder`
**Created**: 2026-05-12
**Status**: Draft
**Issue**: [#91](https://github.com/lambdasistemi/amaru-treasury-tx/issues/91)
**Input**: "What about making sure the remainder is split on the swaps?"

## Background

The swap-wizard's chunk emitter (`mkChunks` in `lib/Amaru/Treasury/IntentJSON.hs` and the parallel counter `chunkCountFor` in `lib/Amaru/Treasury/Tx/SwapWizard.hs`) emits `full + 1` chunks whenever the total amount doesn't divide evenly by the chosen `chunkSize`. The "+1" chunk holds the raw remainder regardless of size, which produces a dust output when `--split N` is used: floor division leaves a remainder strictly less than `N`, so the wizard emits a swap-order whose `extraPerChunkLovelace` overhead (3,280,000 lovelace on mainnet) dwarfs the value it carries.

A live re-run of the famous swap on mainnet at tip slot 187,013,261 produced 34 swap-orders: 33 of value `12,371,863,797` plus one of value `3,280,005` carrying only 5 lovelace of swap. The dust chunk cannot fill on Sundae anyway, so the treasury loses 3,280,000 lovelace of min-UTxO + protocol fee for nothing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — `--split N` no longer produces dust (Priority: P1)

Operator runs `swap-wizard --split 33 --usdm 100000 --min-rate 0.245 …` on the famous swap inputs. The emitted intent contains exactly **33** swap-orders summing to the original amount, with chunk values within 1 lovelace of each other. No dust output.

**Why this priority**: This is the bug fix. It saves 3,280,000 lovelace per dust-y run and matches the operator's "split into N chunks" semantic intent.

**Independent Test**: Run the wizard pipeline live against mainnet. `swap.report.json`'s output-role table lists exactly N swap-order outputs, each within 1 lovelace of `amount / N`.

**Acceptance Scenarios**:

1. **Given** `amount = 408_163_265_306, chunkSize = 12_368_583_797`, **When** the wizard emits chunks, **Then** it produces 33 outputs: 5 of value `12_368_583_798` and 28 of value `12_368_583_797`, summing to exactly `amount`.
2. **Given** a clean-divide case (`amount = 100, chunkSize = 25`), **When** the wizard emits chunks, **Then** it produces 4 outputs of value 25 each.
3. **Given** `amount = 7, chunkSize = 2`, **When** the wizard emits chunks, **Then** it produces 3 outputs: 1 of value 3 and 2 of value 2.

---

### User Story 2 — `--chunk-usdm X` keeps "exact chunks of size X" semantics (Priority: P2)

Operator specifies `--chunk-usdm X` meaning "make chunks of size X". When the total amount minus the operator-specified chunk sizes leaves a substantial remainder (≥ the number of full chunks), the wizard emits the remainder as a separate output, matching today's behavior.

**Why this priority**: The chunk-usdm flag's contract is "every chunk is exactly X". Distributing the remainder across chunks would silently inflate them. The new rule "distribute only when `rem < full`" preserves this contract because `rem ≥ full` is the typical chunk-usdm shape.

**Independent Test**: Run the existing golden fixture (`amount = 408_163_265_306, chunkSize = 12_500_000_000`). The wizard emits the same 33 outputs it does today (32 × `12_500_000_000` + 1 × `8_163_265_306`).

**Acceptance Scenarios**:

1. **Given** the existing fixture inputs (`chunkSize 12.5 B`, `rem 8.16 B`, `full 32`), **When** the wizard emits chunks, **Then** the output list is byte-identical to today's golden.
2. **Given** `--chunk-usdm` with `rem` much larger than `full`, **When** the wizard emits chunks, **Then** the last chunk holds `rem` lovelace exactly.

---

### User Story 3 — Edge cases keep working (Priority: P3)

`amount < chunkSize`, `amount == chunkSize × k` for exact multiples, etc.

**Acceptance Scenarios**:

1. **Given** `chunkSize <= 0`, **When** asking for chunks, **Then** the wizard refuses (existing path: `WizardChunkSizeNotPositive` / `WizardChunkSizeExceedsAmount`).
2. **Given** `amount < chunkSize` (and the wizard accepted it, which today's `wizardToTreasuryIntent` validates), **When** chunks are emitted, **Then** the wizard produces a single output of value `amount`.
3. **Given** `amount` is an exact multiple of `chunkSize`, **When** chunks are emitted, **Then** the wizard produces `amount / chunkSize` outputs of value `chunkSize`.

---

## Functional Requirements

- **FR-1** New pure helper `chunkLovelaces :: Integer -> Integer -> [Integer]` returns the per-chunk lovelace values. Invariant: `sum (chunkLovelaces a c) == a` for all non-negative `a, c > 0`.
- **FR-2** The rule is:
  - `c <= 0` → `[]`
  - `full == 0` → `[rem]` (single small chunk)
  - `rem == 0` → `replicate full c`
  - `0 < rem < full` → `replicate rem (c+1) ++ replicate (full - rem) c` (distribute one extra lovelace into the first `rem` chunks)
  - `rem >= full` → `replicate full c ++ [rem]` (current behavior)
- **FR-3** `mkChunks` (in `Amaru.Treasury.IntentJSON`) emits one `SwapOrderOut` per element of `chunkLovelaces`. The per-output USDM scales by chunk lovelace via the existing `usdm` helper.
- **FR-4** `chunkCountFor` (in `Amaru.Treasury.Tx.SwapWizard`) equals `length . chunkLovelaces`. Treasury leftover and redeemer amount math (`amount + chunkCount * extraPerChunkLovelace`) stays consistent.
- **FR-5** A QuickCheck property test pins the sum invariant.
- **FR-6** Existing golden fixture (`swap-wizard/answers.json` + `env.json`, `swap/expected.cbor`) round-trips byte-identical because `rem 8.16 B >= full 32` — falls into the unchanged branch.
- **FR-7** A new unit test exercises the dust-fold case (`amount = 408_163_265_306, chunkSize = 12_368_583_797`) and asserts exactly 33 outputs.
- **FR-8** Live mainnet re-verification: the same swap-wizard command used in [issue #91 §"Concrete repro"](https://github.com/lambdasistemi/amaru-treasury-tx/issues/91) emits 33 swap-orders (not 34) and the treasury leftover recovers 3,280,000 lovelace vs. today's behaviour.

## Out of Scope

- Touching the bash recipe; the parity check is informational.
- Changing `--chunk-usdm` semantics for substantial remainders.
- Adjusting `extraPerChunkLovelace` or the per-chunk overhead model.

## Success Criteria

- `nix develop -c just ci` green: build, unit, golden, red, smoke, format, lint, release-check.
- Live mainnet run produces 33 swap-orders for the famous-swap inputs.
- `cmp` of the bash CBOR and the new Haskell CBOR shows the same swap-order count and matching wallet-fee semantics (~1 ADA contribution from wallet).
