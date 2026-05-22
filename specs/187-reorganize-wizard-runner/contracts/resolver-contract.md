# Contract — `ReorganizeResolverEnv` + `resolveReorganize`

**Slice**: S1 (Library half)
**Module**: `Amaru.Treasury.Tx.ReorganizeWizard`
**Mirrors**: `StakeRewardInitResolverEnv` +
`resolveStakeRewardInitScriptAccount`

This contract pins the resolver-env field signatures and the
resolver's call ordering. Drift here changes the unit-test mock
shape and the live-runner wiring; both must update together.

## Resolver-env signature

```haskell
data ReorganizeResolverEnv m = ReorganizeResolverEnv
    { sreReadMetadata
        :: !(FilePath -> m (Either String TreasuryMetadata))
    , sreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    , sreQueryTreasuryUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    , sreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    }
```

| Field | Live impl | Mock impl |
|---|---|---|
| `sreReadMetadata` | thin wrapper `readMetadataSafely path = try (readMetadataFile path)` mapping `IOException` → `Left (show ioe)` | per-scenario canned `Right metadata` or `Left "<msg>"` |
| `sreQueryWalletUtxos` | `Cli.Common.queryFlat backend` | per-scenario canned list |
| `sreQueryTreasuryUtxos` | `Cli.Common.queryFlat backend` (same call, different address argument) | per-scenario canned list |
| `sreComputeUpperBound` | `\choice -> fmap (fmap unwrapSlot) <$> queryUpperBoundSlot backend choice` | per-scenario canned `Right slot` or `Left HorizonError` |

## Resolver ordering (cheap-first)

```text
1. Devnet guard          (string compare)
2. Metadata read         (file read + JSON parse)
3. Scope lookup          (Map lookup)
4. Scope-owner check     (Maybe match)
5. Wallet query          (chain query)
6. selectWallet 1        (pure)
7. Treasury query        (chain query)
8. count >= 2            (pure)
9. Sort by (TxId, TxIx)  (pure, errors out on per-row parse failure)
10. Upper-bound          (chain query)
11. Assemble env         (pure)
```

Every step has a typed error variant; a `Left` short-circuits to
the caller without touching the remaining steps. The unit test
suite has one scenario per step (per the spec's User Story 2
+ 3 + 4 accumulation) demonstrating the short-circuit.

## Spec assertions (S1)

Each scenario calls
`resolveReorganize env input :: Identity (Either ReorganizeError ReorganizeEnv)`
and asserts on `runIdentity` of the result.

| Scenario | Expected |
|---|---|
| happy path (≥2 treasury UTxOs, healthy wallet, valid metadata, devnet) | `Right ReorganizeEnv{…}` |
| `rriNetwork = "preprod"` | `Left (ReorganizeNonDevnetNetwork "preprod")` |
| metadata read fails | `Left (ReorganizeMetadataReadError "<msg>")` |
| scope not in metadata | `Left (ReorganizeScopeNotInMetadata <scope>)` |
| scope-owner is `Nothing` | `Left (ReorganizeScopeOwnerMissing <scope>)` |
| wallet query empty | `Left ReorganizeWalletShortfall` |
| treasury query 0 rows | `Left (ReorganizeInsufficientTreasuryUtxos 0)` |
| treasury query 1 row | `Left (ReorganizeInsufficientTreasuryUtxos 1)` |
| validity hours = `Just 0` | `Left ReorganizeValidityHoursZero` |
| upper-bound overshoots | `Left (ReorganizeValidityOvershoot _)` |
| treasury row's `txid#ix` malformed | `Left (ReorganizeLedgerFieldParseError "treasuryUtxos[<n>]" _)` |

## Backward compatibility

This is a new contract (no prior shape exists). It mirrors the
sibling `StakeRewardInitResolverEnv` shape but does NOT share the
record type — they have different field sets
(`sreReadMetadata` vs `sreReadRegistry`; treasury-utxos query
vs no-equivalent).
