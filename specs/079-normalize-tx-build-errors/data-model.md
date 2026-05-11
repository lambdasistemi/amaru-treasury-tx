# Data Model: Normalize tx-build Builder Errors

## Entities

### `TreasuryBuildError`

Project-owned expected build failure.

```haskell
data TreasuryBuildError = TreasuryBuildError
    { tbeAction :: !Text
    , tbePhase :: !BuildFailurePhase
    , tbeContext :: ![BuildErrorContext]
    , tbeDiagnostic :: !BuildDiagnostic
    }
```

Validation rules:

- `tbeAction` is one of the supported intent action names rendered for operators (`swap`, `disburse`, `withdraw`, or `reorganize` when it ships).
- `tbePhase` identifies where the expected failure occurred.
- `tbeContext` is an ordered outer-to-inner list of structured context entries added by runner boundaries.
- `tbeDiagnostic` carries the stable code and fields used by report/CLI rendering.

Context composition:

```haskell
withBuildErrorContext
    :: BuildErrorContext -> TreasuryBuildError -> TreasuryBuildError
withBuildErrorContext ctx err =
    err{tbeContext = ctx : tbeContext err}
```

A pure exception-throwing compatibility expression can use:

```haskell
mapException
    ( \(TreasuryBuildException err) ->
        TreasuryBuildException (withBuildErrorContext ctx err)
    )
```

For `IO` actions that use `throwIO`, use a typed `try`/`catch` wrapper that applies the same `TreasuryBuildException -> TreasuryBuildException` function. In both cases the transformation preserves structure while adding context.

### `BuildErrorContext`

Typed context attached as the failure moves outward.

```haskell
data BuildErrorContext
    = ContextIntentAction !Text
    | ContextBuildPhase !BuildFailurePhase
    | ContextWalletInput !Text
    | ContextReportDestination !FilePath
    | ContextNetwork !Text
```

Rules:

- Context entries are never rendered by concatenating string prefixes at the producer site.
- The renderer decides which context entries are relevant for CLI text and report messages.

### `BuildFailurePhase`

Where the build failed.

```haskell
data BuildFailurePhase
    = BuildPhaseInputResolution
    | BuildPhaseBalance
    | BuildPhaseFeeAlignment
    | BuildPhaseScriptEvaluation
    | BuildPhaseValidation
    | BuildPhaseUnsupportedAction
```

### `BuildDiagnostic`

Normalized failure variants.

```haskell
data BuildDiagnostic
    = DiagnosticInsufficientFee
        { upstreamRequiredLovelace :: !Integer
        , upstreamAvailableLovelace :: !Integer
        }
    | DiagnosticFeeNotConverged
    | DiagnosticCollateralShortfall
        { requiredCollateralLovelace :: !Integer
        , availableCollateralLovelace :: !Integer
        }
    | DiagnosticEvalFailure
        { scriptPurpose :: !Text
        , evaluatorMessage :: !Text
        }
    | DiagnosticChecksFailed
        { validationMessages :: ![Text]
        }
    | DiagnosticBumpFeeFailed
        { bumpFeeMessage :: !Text
        }
    | DiagnosticMissingUtxos
        { missingUtxos :: ![Text]
        }
    | DiagnosticFeeAlignmentFailed
        { feeAlignmentMessage :: !Text
        }
    | DiagnosticUnsupportedAction
        { unsupportedAction :: !Text
        }
```

Validation rules:

- Codes are derived from constructors by `buildDiagnosticCode`.
- Lists render in deterministic input order.
- `DiagnosticInsufficientFee` labels upstream fields and does not call either field a shortfall unless implementation can prove the calculation.

### `TreasuryBuildException`

Compatibility exception wrapper.

```haskell
newtype TreasuryBuildException =
    TreasuryBuildException TreasuryBuildError
```

Rules:

- `displayException` delegates to the normalized renderer.
- New CLI code should prefer the `Either` entry point over catching this exception for expected failures.
- Compatibility code may use `mapException` for pure exception expressions, or the same mapping through typed `try`/`catch` for `IO`, to wrap a lower-level `TreasuryBuildException` with additional `BuildErrorContext`.

### Existing `BuildFailure`

The existing report entity remains:

```haskell
data BuildFailure = BuildFailure
    { bfCode :: !Text
    , bfMessage :: !Text
    }
```

Mapping:

- `bfCode = buildDiagnosticCode tbeDiagnostic`
- `bfMessage = renderTreasuryBuildError treasuryBuildError`

## State Flow

```text
Upstream BuildError / local runner failure
  -> TreasuryBuildError
  -> optional mapException enrichment at exception boundaries
  -> CLI stderr message
  -> optional TxBuildOutputFailure { code, message }
```

Expected failures should not travel through `SomeException` in `app/Main.hs` once the typed entry point is available.
