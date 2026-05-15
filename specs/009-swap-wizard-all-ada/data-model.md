# Data Model: Swap Wizard All ADA Mode

## SwapTarget

Represents the operator's target mode.

Fields:

- `TargetUsdm Double`: existing fixed USDM target.
- `TargetAllAda`: new max-spend target.

Validation:

- Exactly one target must be present.
- `TargetAllAda` is incompatible with `ChunkUsdm`.

## AllAdaPlan

Pure calculation result for max-spend mode.

Fields:

- `aapSelectedTreasuryUtxos :: [Text]`: pure ADA treasury outrefs chosen for the intent.
- `aapAvailableLovelace :: Integer`: sum of selected pure ADA UTxOs.
- `aapAmountLovelace :: Integer`: ADA sent into swap chunks.
- `aapChunkSizeLovelace :: Integer`: chunk size derived from amount and split count.
- `aapChunkCount :: Integer`: number of chunks produced by existing chunk semantics.
- `aapExtraPerChunkLovelace :: Integer`: existing Sundae per-order overhead.
- `aapOverheadLovelace :: Integer`: `chunkCount * extraPerChunkLovelace`.
- `aapLeftoverLovelace :: Integer`: lovelace retained in the treasury output.
- `aapImpliedUsdm :: Integer`: sum of per-chunk USDM datum amounts.
- `aapRateNumerator :: Integer`: effective minimum rate numerator.
- `aapRateDenominator :: Integer`: effective minimum rate denominator.

Validation:

- `split >= 1`.
- `amountLovelace >= split`.
- `leftoverLovelace >= minUtxoDepositLovelace`.
- `availableLovelace = amountLovelace + overheadLovelace + leftoverLovelace`.

## ResolverInput

Existing resolver input gains target information.

Fields affected:

- Fixed mode keeps `riAmountLovelace` and `riChunkSizeLovelace`.
- All-ADA mode carries a split count and asks the resolver to derive amount and chunk size after UTxO query.

## TreasurySelection

Existing intent-facing selection remains unchanged.

Fields:

- `tsInputs`: selected treasury outrefs.
- `tsLeftoverLovelace`: leftover output lovelace.

For all-ADA mode, the selected inputs and leftover come from `AllAdaPlan`.
