# Contract — `WizardFailure` and `BuildFailure`

## Versioning

The constructor set of `WizardFailure` and `BuildFailure` is part of the public contract of `lib/Amaru/Treasury/Wizard/Failure.hs`. Adding a constructor is non-breaking. Renaming, removing, or changing a payload type is breaking and requires a coordinated update across every caller (CLI, HTTP, future GUI).

## JSON schema (derived via Generic + Aeson)

Each constructor is tagged in the JSON encoding so the HTTP layer can pattern-match on `"tag"` without depending on Haskell.

### `WizardFailure` examples

```json
{ "tag": "InputMalformed",       "field": "wallet_addr", "reason": "bech32 decode failed: invalid checksum" }
{ "tag": "InputOutOfRange",      "field": "validity_hours", "reason": "must be > 0 and <= 168, got 0" }
{ "tag": "InputInputControlBad", "reason": "exclude-utxo set intersects force-utxo set: tx#0,tx#1" }
{ "tag": "ResolveNetworkUnknown","reason": "no profile matches network magic 12345" }
{ "tag": "ResolveMetadataMissing","path": "/etc/amaru-treasury/metadata.json" }
{ "tag": "ResolveRegistryVerifyFailed","detail": { … } }
{ "tag": "ResolveWalletShortfall","available_lovelace": 4500000, "required_lovelace": 7200000 }
{ "tag": "InternalTranslateError","reason": "wizardToTreasuryIntent: ChunkSizeBelowMinUtxo" }
```

### `BuildFailure` examples

```json
{ "tag": "BuildMinUtxoViolation","have_lovelace": 980000, "need_lovelace": 1100000 }
{ "tag": "BuildScriptRefMissing","script_hash": "1a2b3c…" }
{ "tag": "BuildResolveUtxo","missing": ["tx#0"], "reason": "input no longer in ledger" }
```

## `FieldId` JSON enum

| Haskell constructor | JSON string |
|---|---|
| `FieldScope`             | `"scope"` |
| `FieldWalletAddr`        | `"wallet_addr"` |
| `FieldUsdm`              | `"usdm"` |
| `FieldAllAda`            | `"all_ada"` |
| `FieldSplit`             | `"split"` |
| `FieldRate`              | `"rate"` |
| `FieldSlippageBps`       | `"slippage_bps"` |
| `FieldValidityHours`     | `"validity_hours"` |
| `FieldDescription`       | `"description"` |
| `FieldJustification`     | `"justification"` |
| `FieldDestinationLabel`  | `"destination_label"` |
| `FieldEvent`             | `"event"` |
| `FieldLabel`             | `"label"` |
| `FieldExtraSigner`       | `"extra_signer"` |
| `FieldMetadataPath`      | `"metadata"` |
| `FieldExcludeUtxo`       | `"exclude_utxo"` |
| `FieldForceUtxo`         | `"force_utxo"` |

JSON tags match the CLI flag names (with `--` stripped) so a UI can derive a flag for diagnostics.

## Helpers exported from `Wizard/Failure.hs`

```haskell
-- | True for the Input* family.
isInput :: WizardFailure -> Bool

-- | Just the field if the failure carries one.
fieldOf :: WizardFailure -> Maybe FieldId

-- | Human-readable single-line render for the CLI exit message.
renderWizardFailure :: WizardFailure -> Text

-- | Same for BuildFailure.
isInputBuild :: BuildFailure -> Bool
fieldOfBuild :: BuildFailure -> Maybe FieldId
renderBuildFailure :: BuildFailure -> Text
```

## Coverage invariant (test)

A QuickCheck property in `test/unit/Amaru/Treasury/Wizard/FailureSpec.hs` asserts:

```haskell
prop_every_variant_has_a_triggering_test :: Property
prop_every_variant_has_a_triggering_test =
    forAll genWizardFailureTag $ \tag ->
        tag `elem` testedTags
```

`testedTags` is collected from the FailureSpec describe-blocks at compile time (a `[Tag]` constant the test file maintains). If a new constructor lands without a triggering test, this property fails. Same applies to `BuildFailure`.
