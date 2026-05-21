# Contract — `reorganizeProgram`

The pure `TxBuild` program for the reorganize action. Mirrors
`Tx.Withdraw.withdrawProgram` / `Tx.Disburse.disburseAdaProgram`'s
contract style.

## Signature

```haskell
reorganizeProgram
    :: ReorganizeIntent
    -> MaryValue
    -- ^ preserved-total value, computed by the runner from
    --   ChainContext.ccUtxos folded over rgiTreasuryUtxos
    -> TxBuild q e ()
```

## Sequence (exact, observable by the materialization golden)

| # | Operation | TxBuild combinator | Notes |
|---|---|---|---|
| 1 | spend wallet fuel | `spend rgiWalletUtxo` | discard result (returned `Item q` is unused) |
| 2 | mark as collateral | `collateral rgiWalletUtxo` | same TxIn as the spend |
| 3 | spend each treasury UTxO | `forM_ (toList rgiTreasuryUtxos) $ \\txin -> void (spendScript txin (RawPlutusData reorganizeRedeemer))` | order: as listed in the intent (the resolver / wizard chose the order; the builder does not reorder) |
| 4 | reference deployed treasury script | `reference rgiTreasuryDeployedAt` | |
| 5 | reference registry NFT | `reference rgiRegistryDeployedAt` | read-only |
| 6 | reference deployed permissions script | `reference rgiPermissionsDeployedAt` | A1 parity |
| 7 | permissions withdraw-zero | `withdrawScript rgiPermissionsRewardAccount (Coin 0) (RawPlutusData emptyListRedeemer)` | A1 parity — the empty-list redeemer |
| 8 | continuing output | `_ <- payTo rgiTreasuryAddress preservedValue` | one output; carries the full preserved `MaryValue` |
| 9 | required signer | `requireSignature rgiScopeOwnerSigner` | single key hash; never the list disburse uses |
| 10 | validity bound | `validTo rgiUpperBound` | `invalid_hereafter` slot |

**Out of scope for the pure program:**

- CIP-1694 rationale metadata — applied by the runner via
  `setMetadata label1694 (tsRationale shared)` (mirror
  `runWithdrawAction`).
- Change output — appended by the balancer after the pure program
  emits its outputs.
- Fee — alignment by `alignCardanoCliBuildFee` post-processing.
- Final phase-1 validation — the runner's job.

## Invariants the program REQUIRES of the runner

1. Every TxIn referenced by the intent exists in
   `ChainContext.ccUtxos` (the runner has already validated this
   via `missingUtxosError`).
2. `preservedValue` is the exact `MaryValue` sum of
   `ccUtxos ! txin` for `txin <- toList rgiTreasuryUtxos`. The
   program does not recompute or validate this.
3. All `rgiTreasuryUtxos` live at `rgiTreasuryAddress` (the
   runner / translator has enforced this; the program does not
   check).
4. `rgiTreasuryUtxos` is non-empty (the type guarantees this).

## What the program does NOT do

- It does not read chain state.
- It does not call the script evaluator.
- It does not produce a `BuildResult`.
- It does not validate final phase-1 checks.
- It does not check the address parity of the inputs.
- It does not decide signer order.

## Materialization golden assertion (S2)

After running `runReorganizeBuild` on the fixture
`ReorganizeIntent`, the golden harness asserts:

- `serialize (eraProtVerLow @ConwayEra) (tx :: ConwayTx) ==
   expected.cbor` (the canonical golden file).
- `tx ^. bodyTxL . inputsTxBodyL` contains every TxIn from
  `rgiTreasuryUtxos` plus `rgiWalletUtxo`.
- `tx ^. bodyTxL . referenceInputsTxBodyL` contains
  `rgiTreasuryDeployedAt`, `rgiRegistryDeployedAt`, and
  `rgiPermissionsDeployedAt`.
- `tx ^. bodyTxL . outputsTxBodyL` length is `2` (continuing
  output + change). The continuing output at index `0` has address
  `rgiTreasuryAddress` and value `preservedValue`.
- `tx ^. bodyTxL . withdrawalsTxBodyL` has exactly one entry, on
  `rgiPermissionsRewardAccount`, value `Coin 0`.
- The redeemer for every treasury input is `Constr 0 []`
  (CBOR `d87980`).
- The redeemer for the withdrawal is `List []` (CBOR `80`).
- The required-signers list contains `rgiScopeOwnerSigner`.
- The `invalid_hereafter` field equals `rgiUpperBound`.

The CBOR golden plus these structural assertions cover every
behavior the spec lists.
