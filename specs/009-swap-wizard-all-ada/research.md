# Research: Swap Wizard All ADA Mode

## Decision 1: All-ADA Means Pure ADA Treasury UTxOs

**Decision**: In this feature, `--all-ada` selects only treasury UTxOs with no native assets.

**Rationale**: The current swap intent path returns only leftover lovelace for swap. Selecting token-bearing treasury UTxOs would require preserving USDM and other assets on the leftover output, which is a different feature with larger accounting risk. Pure ADA UTxOs match the issue's live observation of a pure ADA remainder and keep the ledger output valid without asset loss.

**Alternatives considered**: Select all UTxOs and preserve token bundles. Rejected for this slice because it expands the swap intent and report accounting surface.

## Decision 2: Reserve Minimum Leftover Before Swap Amount

**Decision**: The max-spend calculation reserves `minUtxoDepositLovelace` for the treasury leftover output.

**Rationale**: The swap builder always emits a treasury leftover output. A zero or dust leftover risks ledger rejection. The repo already centralizes the minimum deposit constant.

**Alternatives considered**: Allow zero leftover and rely on balancing or ledger failure. Rejected because the wizard should fail before emitting an invalid intent.

## Decision 3: All-ADA Supports `--split`, Not `--chunk-usdm`

**Decision**: `--all-ada` requires `--split N` and rejects `--chunk-usdm`.

**Rationale**: `--chunk-usdm` is phrased in target USDM, but all-ADA derives target USDM after rate application. Supporting it would either reduce the "all" amount or create surprising extra remainder behavior.

**Alternatives considered**: Treat `--chunk-usdm` as an approximate chunk target and derive chunk count. Rejected as ambiguous for an operator command that spends a live treasury remainder.

## Decision 4: Keep Fixed-USDM Path Unchanged

**Decision**: Existing `--usdm` behavior remains the default fixed-target mode.

**Rationale**: Existing docs, fixtures, and operator workflows rely on fixed target USDM semantics. The new target parser should be an additive mode.

**Alternatives considered**: Make `--all-ada` the default when `--usdm` is absent. Rejected because targetless commands should fail clearly.

## Decision 5: Trace the Calculation in One Value Event

**Decision**: Add a trace event for all-ADA calculation facts: available pure ADA, amount, implied USDM, leftover, split, overhead, and rate.

**Rationale**: The feature moves arithmetic into the tool; reviewers need a stable line that explains the produced intent.

**Alternatives considered**: Rely on existing treasury selection and chunk trace lines. Rejected because they do not show the implied USDM target or the pre-reservation calculation.
