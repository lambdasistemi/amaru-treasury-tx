# Contract — `Amaru.Treasury.Build` dispatcher `SReorganize` arm

After S3, the unified dispatcher's `SReorganize` branch matches the
shape every other action arm uses. This file documents the exact
shape so the slice-3 reviewer can verify the diff against a contract,
not against the dispatcher's pre-S3 stub.

## Before (current main, this branch up to S2)

```haskell
SReorganize ->
    throwE $
        buildError
            BuildActionReorganize
            BuildPhaseUnsupported
            (DiagnosticUnsupportedAction "reorganize")
```

(See `lib/Amaru/Treasury/Build.hs:150–155`.)

## After (S3)

```haskell
SReorganize ->
    withExceptT
        (nestActionBuildError BuildActionReorganize)
        ( runReorganizeAction
            ctx
            translated
            (tsRationale shared)
            (tsWalletAddr shared)
        )
```

Direct mirror of `SWithdraw` (lines 141–149).

## Export list change

Add `runReorganizeBuild` to `Amaru.Treasury.Build`'s explicit
export list, alongside `runDisburse`, `runSwap`, `runSwapCancel`,
`runWithdraw` (lines 37–41):

```haskell
  , runReorganizeBuild
```

Insert in alphabetical position between `runDisburse` and `runSwap`.

## Translate-intent arm change

Before (`lib/Amaru/Treasury/IntentJSON.hs:1468–1470`):

```haskell
SReorganize ->
    Left
        "translateIntent: 'reorganize' not yet shipped (#46)"
```

After:

```haskell
SReorganize -> translateReorganize ti
```

with `translateReorganize` implemented next to the other
per-action translators in the same module. Reference shape:

```haskell
translateReorganize
    :: TreasuryIntent 'Reorganize
    -> Either String (TranslatedShared, ReorganizeIntent)
translateReorganize ti = do
    shared <- translateShared (tiSomeShared ti)
    let inputs = tiPayload ti
    -- Defensive: NonEmpty is guaranteed by parser, but a
    -- hand-crafted JSON could bypass it; re-check here.
    -- (NonEmpty.nub kills duplicates; failure is an explicit Left.)
    treasuryUtxos <- case NonEmpty.nub (riTreasuryUtxos inputs) of
        utxos
            | length utxos == length (riTreasuryUtxos inputs) ->
                Right utxos
            | otherwise ->
                Left "ReorganizeInputs.treasuryUtxos: duplicates"
    Right
        ( shared
        , ReorganizeIntent
            { rgiWalletUtxo = riWalletUtxo inputs
            , rgiTreasuryUtxos = treasuryUtxos
            , rgiTreasuryAddress = riTreasuryAddress inputs
            , rgiTreasuryDeployedAt = riTreasuryDeployedAt inputs
            , rgiRegistryDeployedAt = riRegistryDeployedAt inputs
            , rgiPermissionsRewardAccount = riPermissionsRewardAccount inputs
            , rgiPermissionsDeployedAt = riPermissionsDeployedAt inputs
            , rgiScopeOwnerSigner = riScopeOwnerSigner inputs
            , rgiUpperBound = riUpperBound inputs
            }
        )
```

(The exact form of `translateShared` follows the disburse / withdraw
peers; slice executor reads them at S3 to match the pattern.)

The multi-scope address-parity check (research §10) is deferred to
S3's slice executor — the executor decides whether the check fits
here or in the runner based on what `TranslatedShared` exposes at
the translate layer.

## Test coverage required by this contract

Listed in `plan.md`'s "Acceptance scenario coverage matrix"; the
most important ones for the dispatcher arm specifically are:

| Test | Slice | Asserts |
|---|---|---|
| `ReorganizeGoldenSpec` (end-to-end after S3) | S2→S3 | `runFromIntent ctx some == Right` with golden bytes |
| `ReorganizeDispatchSpec` (S3 new) | S3 | `runFromIntentEither ctx some` is `Right _` |
| `IntentJSONSpec` (S1, S3 minor extension) | S1 | round-trip property; S3 may add a `translateIntent` smoke |

## Failure-mode coverage

The dispatcher arm must surface the right action-namespaced error
for each diagnostic:

- `DiagnosticMissingUtxos` → `BuildActionReorganize` (not Intent).
- `DiagnosticTranslateFailed` (from `translateReorganize`) →
  `BuildActionIntent` (matches the other arms' behaviour — the
  translate failure is a pre-action concern).
- `DiagnosticChecksFailed` (from `validateFinalPhase1`, including
  exec-units overflow after #191) → `BuildActionReorganize`.

The `nestActionBuildError BuildActionReorganize` wraps action
errors; translate-time failures arrive via the `Left` from
`translateIntent` and stay namespaced under `BuildActionIntent`.

## Why this matters for review

The dispatcher is the seam between the JSON layer and the per-action
runners. A bug here means the wrong error tag, the wrong runner, or
silent fall-through. The contract above is the reviewer's checklist
for S3.
