# Phase 1 — Data Model

**Feature**: typed `buildSwapTx` + HTTP + `/operate` CBOR & Report
**Branch**: `270-build-swap-typed`
**Date**: 2026-05-24

Five new or extended entities. Field shapes are the contract; module placement is fixed by the plan (R1, R3, R4 in [research.md](./research.md)).

---

## 1. `BuildFailure` (NEW)

**Module**: `Amaru.Treasury.Wizard.Failure`
**Purpose**: Sum type returned in the `Left` arm of `buildSwapTx`. One constructor per distinct failure mode in the `Build.Swap` pipeline. Every constructor's payload carries enough data for a UI to highlight the offending step / field.

Initial constructor enumeration (subject to R2 walk during implementation; may grow by one or two if extra exit sites surface, never shrink):

| Constructor                                | Payload                                                | Triggering condition                                                                                  |
|--------------------------------------------|--------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `WalletAddressUnresolved`                  | `{ address :: Text }`                                  | The wallet bech32 address has no UTxOs on the supplied `Backend`.                                     |
| `WalletUtxoStale`                          | `{ missing :: [TxIn] }`                                | One or more `TxIn`s referenced by the `SwapIntent.wallet` have been spent since intent was assembled. |
| `WalletUnderfunded`                        | `{ required :: Coin, available :: Coin }`              | Coin selection can't cover the swap amount + extras + fees from the wallet UTxOs.                     |
| `TreasuryUtxoStale`                        | `{ missing :: [TxIn] }`                                | The treasury UTxOs referenced by the intent are no longer at the treasury address.                    |
| `SundaeOrderRejected`                      | `{ reason :: Text }`                                   | The constructed sundae order fails sundae's on-chain validator at evaluation.                         |
| `BalancingFailed`                          | `{ reason :: Text }`                                   | Ledger-side balancing (`balanceTx`) returns an error.                                                 |
| `FeeEstimationFailed`                      | `{ reason :: Text }`                                   | `estimateMinFeeTx` fails (e.g. malformed witness skeleton).                                           |
| `ScriptEvaluationFailed`                   | `{ script :: Text, reason :: Text }`                   | A reference script evaluation returns a non-success result.                                           |
| `MetadataInvalid`                          | `{ reason :: Text }`                                   | The CIP-25/CIP-674 metadata block fails encoding.                                                     |
| `BackendUnavailable`                       | `{ reason :: Text }`                                   | The `Backend` errored on a read (node socket gone, chain rollback).                                   |
| `ProtocolParametersMissing`                | `{ }`                                                  | `Backend.getPParams` returned no result (impossible in practice, kept for total coverage).             |
| `ReportSerialisationFailed`                | `{ reason :: Text }`                                   | The `Report` value failed to round-trip its JSON encoding (defensive — should never fire).            |

**Invariant**: every constructor is reachable from a test in `BuildSwapSpec.hs` (FR-007, SC-002). The harness derives the constructor list and asserts coverage.

**Derived instances**: `Eq`, `Show`, `Generic`. JSON encoding via `aeson`'s `Generic` derivation produces `{"tag": "WalletUnderfunded", ...}` which is then flattened by `BuildSwap.hs` into the `SwapBuildResponse.buildFailure` payload (R4).

---

## 2. `BuildEvent` (NEW)

**Module**: `Amaru.Treasury.Wizard.Event`
**Purpose**: Sum type emitted via `Tracer IO BuildEvent` during `buildSwapTx`. Informational only (FR-004).

Initial constructor set:

| Constructor                | Payload                                       | Emitted when                                                       |
|----------------------------|-----------------------------------------------|--------------------------------------------------------------------|
| `ResolvingPParams`         | `{ }`                                         | About to query the backend for protocol parameters.                |
| `SelectingWalletInputs`    | `{ address :: Text }`                         | About to scan the wallet's UTxO set.                               |
| `BuildingSundaeOrder`      | `{ direction :: Text }`                       | About to construct the sundae order datum (ADA→USDM or reverse).   |
| `BalancingTx`              | `{ inputs :: Int, outputs :: Int }`           | About to call the ledger's balancing routine.                      |
| `SerialisingTx`            | `{ }`                                         | About to encode the balanced body to CBOR.                         |
| `WritingReport`            | `{ txid :: Text }`                            | About to compute the txid + assemble the `Report` value.           |

**Rendering**: `renderEvent :: BuildEvent -> Text`, mirrors `WizardEvent`'s render. Lives in the same module so the stderr `Tracer` in `runBuildSwap` (HTTP path) can reuse it directly.

**Invariant**: A successful `buildSwapTx` with `nullTracer` MUST produce the same `Right (CborHex, Report)` value as the same call with a real tracer. Property test in `BuildSwapSpec.hs`.

---

## 3. `Wizard.Swap.buildSwapTx` (NEW EXPORT)

**Module**: `Amaru.Treasury.Wizard.Swap`
**Signature**:

```haskell
buildSwapTx
  :: GlobalOpts
  -> Backend
  -> SwapIntent
  -> Tracer IO BuildEvent
  -> ExceptT BuildFailure IO (CborHex, Report)
```

**Contract**:
- Uses the supplied `Backend` for all chain reads (`getPParams`, UTxO lookups, tip slot). Does NOT open or close the backend (CLI / HTTP host owns the lifecycle).
- Every step that could fail emits a typed `BuildFailure` via `throwE`. The handler / CLI wrapper pattern-matches on the variant; the host process is never killed from inside `buildSwapTx`.
- Tracer is informational; reads happen unconditionally; control flow is identical with `nullTracer`.
- Side effects scoped to: chain reads via `Backend`, no file I/O, no logging beyond the tracer.

**Companion** (also in `Wizard.Swap`):

```haskell
sysexitsForBuild :: BuildFailure -> ExitCode
```

Mirrors `sysexitsFor` for `WizardFailure`. Used by CLI wrappers to keep the existing 64 / 69 / 70 mapping (FR-005).

---

## 4. `SwapBuildResponse` (EXTENDED)

**Module**: `Amaru.Treasury.Api.BuildSwap`
**Existing shape** (#263):
```haskell
data SwapBuildResponse = SwapBuildResponse
  { intentJson     :: Maybe Json
  , intentFailure  :: Maybe FailureTag
  , internalError  :: Maybe Text
  , cliCommand     :: Text
  } deriving (Generic, ToJSON, FromJSON)
```

**Extended shape**:
```haskell
data SwapBuildResponse = SwapBuildResponse
  { intentJson     :: Maybe Json
  , intentFailure  :: Maybe FailureTag
  , cborHex        :: Maybe Text          -- NEW
  , report         :: Maybe Json          -- NEW (encoded Report as raw JSON)
  , buildFailure   :: Maybe FailureTag    -- NEW
  , internalError  :: Maybe Text
  , cliCommand     :: Text
  } deriving (Generic, ToJSON, FromJSON)
```

**Arm encoding** (per R4 — exactly one of these patterns is in play on any given response):

| Arm                  | `intentJson` | `intentFailure` | `cborHex` | `report` | `buildFailure` | `internalError` |
|----------------------|--------------|-----------------|-----------|----------|----------------|-----------------|
| Success              | Just         | Nothing         | Just      | Just     | Nothing        | Nothing         |
| Intent failure       | Nothing      | Just            | Nothing   | Nothing  | Nothing        | Nothing         |
| Build failure        | Just         | Nothing         | Nothing   | Nothing  | Just           | Nothing         |
| Internal failure     | Nothing      | Nothing         | Nothing   | Nothing  | Nothing        | Just            |

`cliCommand` is always populated (it's the copy-paste recipe; deterministic from the request body alone).

**Backwards compatibility**: All new fields are `Maybe`. Existing consumers that only read `intentJson` keep working unchanged (R7).

---

## 5. `FailureTag` (UNCHANGED, reused)

**Module**: `Amaru.Treasury.Api.BuildSwap`
**Purpose**: The existing wrapper around a failure variant tag, used for `intentFailure` and now also for `buildFailure`. No schema change; the constructor list expands with the addition of `BuildFailure` constructors.

```haskell
data FailureTag = FailureTag
  { tag    :: Text       -- constructor name, e.g. "WalletUnderfunded"
  , field  :: Maybe Text -- form field reference for the frontend
  , detail :: Text       -- one-line human-readable message
  } deriving (Generic, ToJSON, FromJSON)
```

`failureTagOfBuild :: BuildFailure -> FailureTag` lives in `BuildSwap.hs` alongside the existing `failureTag :: WizardFailure -> FailureTag`.

---

## Field reference for the frontend (R4 + FR-012)

The `field` member of `FailureTag` carries a DOM-ish reference so the frontend can highlight the offending input. Mapping:

| `BuildFailure` constructor      | `field` value (frontend `[data-field]` selector)   |
|---------------------------------|----------------------------------------------------|
| `WalletAddressUnresolved`       | `wallet-address`                                   |
| `WalletUtxoStale`               | `wallet-address`                                   |
| `WalletUnderfunded`             | `wallet-address`                                   |
| `TreasuryUtxoStale`             | (no form input — show in preview status only)      |
| `SundaeOrderRejected`           | `rate-mode`                                        |
| `BalancingFailed`               | (no form input — show in preview status only)      |
| `FeeEstimationFailed`           | (no form input — show in preview status only)      |
| `ScriptEvaluationFailed`        | (no form input — show in preview status only)      |
| `MetadataInvalid`               | (no form input — show in preview status only)      |
| `BackendUnavailable`            | (no form input — show in preview status only)      |
| `ProtocolParametersMissing`     | (no form input — show in preview status only)      |
| `ReportSerialisationFailed`     | (no form input — show in preview status only)      |
