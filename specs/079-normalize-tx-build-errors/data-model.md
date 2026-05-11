# Data Model: Normalize tx-build Builder Errors

## Entities

### `BuildError`

Project-owned expected build failure.

```haskell
data BuildError = BuildError
    { beAction :: !Text
    , bePhase :: !BuildFailurePhase
    , beContext :: ![BuildErrorContext]
    , beDiagnostic :: !BuildDiagnostic
    }
```

Validation rules:

- `beAction` is one of the supported intent action names rendered for operators (`swap`, `disburse`, `withdraw`, or `reorganize` when it ships).
- `bePhase` identifies where the expected failure occurred.
- `beContext` is an ordered outer-to-inner list of structured context entries added by runner boundaries.
- `beDiagnostic` carries the stable code and fields used by report/CLI rendering.

### `ActionBuildError`

Action runners may use a smaller nested error while they are still
action-agnostic:

```haskell
data ActionBuildError = ActionBuildError
    { abePhase :: !BuildFailurePhase
    , abeContext :: ![BuildErrorContext]
    , abeDiagnostic :: !BuildDiagnostic
    }
```

Dispatcher boundaries lift that nested error into the public diagnostic
with `withExceptT`:

```haskell
withExceptT
    (nestActionBuildError BuildActionSwap)
    runSwapAction
```

This keeps repeated action context out of lower-level helpers while
preserving a single public `BuildError`.

Context composition:

```haskell
withBuildErrorContext
    :: BuildErrorContext -> BuildError -> BuildError
withBuildErrorContext ctx err =
    err{beContext = ctx : beContext err}
```

A pure exception-throwing compatibility expression can use:

```haskell
mapException
    ( \(BuildException err) ->
        BuildException (withBuildErrorContext ctx err)
    )
```

For `IO` actions that use `throwIO`, use a typed `try`/`catch` wrapper that applies the same `BuildException -> BuildException` function. In both cases the transformation preserves structure while adding context.

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
    = BuildPhaseTranslate
    | BuildPhaseGatherInputs
    | BuildPhaseBuild
    | BuildPhaseFeeAlignment
    | BuildPhaseUnsupported
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

### `BuildException`

Compatibility exception wrapper.

```haskell
newtype BuildException =
    BuildException BuildError
```

Rules:

- `displayException` delegates to the normalized renderer.
- New CLI code should prefer the `Either` entry point over catching this exception for expected failures.
- Compatibility code may use `mapException` for pure exception expressions, or the same mapping through typed `try`/`catch` for `IO`, to wrap a lower-level `BuildException` with additional `BuildErrorContext`.

### Existing `BuildFailure`

The existing report entity remains:

```haskell
data BuildFailure = BuildFailure
    { bfCode :: !Text
    , bfMessage :: !Text
    }
```

Mapping:

- `bfCode = buildDiagnosticCode beDiagnostic`
- `bfMessage = renderBuildError buildError`

## State Flow

```text
Upstream BuildError / local runner failure
  -> ActionBuildError
  -> withExceptT action wrapper
  -> BuildError
  -> optional mapException enrichment at exception boundaries
  -> CLI stderr message
  -> optional TxBuildOutputFailure { code, message }
```

Expected failures should not travel through `SomeException` in `app/Main.hs` once the typed entry point is available.
