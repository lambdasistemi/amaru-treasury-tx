# Data Model — `report-render`

Tracking issue: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This document captures the new and extended Haskell-side data
shapes the renderer needs. All types live under
`lib/Amaru/Treasury/Report/` and adhere to the constitution's
"pure builders, impure shell" rule (no `IO`).

## Existing types extended

### `Amaru.Treasury.Report.TxBuildOutput`

`tx-build --report` writes one top-level envelope. The envelope always
carries the decoded unified intent, then carries either a structured
failure or the successful transaction payload.

```haskell
newtype TxCborHex = TxCborHex Text
    deriving stock (Eq, Ord, Show)

data TxBuildOutput = TxBuildOutput
    { txoIntent :: !SomeTreasuryIntent
    , txoResult :: !TxBuildOutputResult
    }

data TxBuildOutputResult
    = TxBuildOutputFailure !BuildFailure
    | TxBuildOutputSuccess !TxBuildSuccess

data TxBuildSuccess = TxBuildSuccess
    { tbsTxCbor :: !TxCborHex
    , tbsReport :: !TransactionReport
    }
```

The success JSON shape is:

```json
{
  "intent": { "...": "unified intent JSON" },
  "result": {
    "tx-cbor": "84a4...",
    "report": { "...": "mechanical report JSON" }
  }
}
```

The failure JSON shape is:

```json
{
  "intent": { "...": "unified intent JSON" },
  "result": {
    "failure": { "...": "structured build failure JSON" }
  }
}
```

`TxCborHex` is lowercase, non-empty, even-length hex.

### `Amaru.Treasury.Report.TransactionReport`

The nested mechanical report remains the issue #72 report payload. It
does not carry intent, transaction CBOR, or a duplicate transaction
type/action field; those belong to the surrounding `TxBuildOutput`
envelope.

```haskell
data TransactionReport = TransactionReport
    { trSchema        :: !Int
    , trNetwork       :: !Network
    , trWallet        :: !WalletAccounting
    , trScope         :: !ScopeAccounting
    , trIdentity      :: !TransactionIdentity
    , trMetadata      :: !MetadataSummary
    , trOutputs       :: ![ProducedOutput]
    , trReferenceIns  :: ![UtxoSummary]
    , trSigners       :: ![SignerRequirement]
    , trValidation    :: !ValidationFacts
    }
```

The envelope encoder always emits `intent` and `result`. On success,
`result` always emits `tx-cbor` and `report`. On failure, `result`
emits `failure` and MUST NOT emit `tx-cbor` or `report`.

## New types

### `AddressBook` and `IdentityMap`

```haskell
-- | Resolved label for a printable identity.
data RoleLabel = RoleLabel
    { rlText  :: !Text          -- e.g. "network_compliance treasury"
    , rlScope :: !(Maybe ScopeId)
    }
    deriving stock (Eq, Ord, Show)

-- | Resolution outcome for a printable identity.
data Resolved
    = Resolved !RoleLabel
    | Unresolved   -- never bare; always wrapped via formatAddress
    deriving stock (Eq, Show)

-- | Address book: bech32 -> resolved label.
newtype AddressBook = AddressBook
    { abAddresses :: Map Text Resolved }
    deriving stock (Eq, Show)

-- | Identity map: 28-byte key hash -> resolved label.
newtype IdentityMap = IdentityMap
    { imSigners :: Map KeyHash Resolved }
    deriving stock (Eq, Show)
```

### `ResolutionInputs`

The declarative inputs the renderer feeds the resolver.

```haskell
data ResolutionInputs = ResolutionInputs
    { riMetadata    :: !(Maybe TreasuryMetadata)
    , riIntent      :: !SomeTreasuryIntent
    , riReport      :: !TransactionReport
    }
```

### `RenderInputs` and `RenderOutput`

```haskell
data RenderInputs = RenderInputs
    { renderIntent     :: !SomeTreasuryIntent
    , renderTxCbor     :: !TxCborHex
    , renderReport     :: !TransactionReport
    , renderAddresses  :: !AddressBook
    , renderIdentities :: !IdentityMap
    }

newtype RenderOutput = RenderOutput { unRenderOutput :: Text }
```

The pure success renderer has type
`renderSuccessReport :: RenderInputs -> RenderOutput`. A failure
envelope can be rendered only as a diagnostic, never as a signable
transaction review.

### `ReportRenderOpts` (CLI)

```haskell
data ReportRenderOpts = ReportRenderOpts
    { rrInPath       :: !(Maybe FilePath)        -- Nothing = stdin
    , rrOutPath      :: !(Maybe FilePath)        -- Nothing = stdout
    , rrMetadataPath :: !(Maybe FilePath)        -- Nothing = default path if exists
    }
```

`-` is accepted as a stdio alias for `--in` and `--out` and
parsed into `Nothing` (inheriting the default behaviour).

## Resolution priority (FR-018)

`Identity.Resolve.resolveAddress` and `resolveSigner` apply
sources in priority order, returning `Resolved` from the first
match and `Unresolved` if none match:

1. Explicit metadata (`--metadata <path>` or default path).
2. Built-in constants (USDM policy/asset, Sundae pool, Sundae
   protocol fee scripts).
3. Script-hash derivations (Sundae swap-order address parameterised
   by the treasury script hash, registry/permissions/treasury
   deployed-at outputs from the report's reference inputs).
4. Envelope intent (operator-wallet address, scope owner key hashes
   for swap intents).
5. `Unresolved` fallback.

Resolution is total. A miss is never a fail; it is an `Unresolved`
that the renderer wraps in `unresolved (<truncated>)`.

## Transaction-type classification (FR-023)

The leading section's transaction-type label is sourced from the
constructor/type tag of `txoIntent`, expected to be one of
`swap`, `disburse`, `withdraw`, `reorganize`, plus any future
constructor supported by the unified-intent decoder. A malformed or
unsupported intent type is a report decode error. The scope is sourced
from:

- the inline intent's `scope.id`; otherwise, for future non-scoped
  intent shapes,
- the address-book classification of the produced outputs
  (treasury destination → its scope; swap-order destination →
  the parameterising scope); otherwise
- a literal `<unknown scope>` placeholder line.

## Validation rules

- The build path MUST emit `TxBuildOutput` with `txoIntent =
  originatingIntent` for every decoded unified intent.
- On success, `txoResult` MUST carry the exact unsigned transaction
  CBOR bytes as lowercase hex and the nested mechanical report.
- On failure after intent decode, `txoResult` MUST carry structured
  failure data and MUST NOT carry `tx-cbor` or `report`.
- The envelope decoder MUST reject a missing or malformed top-level
  `intent` field.
- The success-result decoder MUST reject a missing, empty, or
  malformed `tx-cbor` field and a missing or malformed nested
  `report`.
- The envelope encoder MUST always emit top-level `intent` and
  `result`.
- `TransactionReport` MUST NOT carry a separate `trAction`,
  transaction-type, intent, transaction CBOR, or equivalent duplicate
  of envelope data.
- The renderer MUST NOT emit a bare bech32 or bare 28-byte hex
  without either a label or `unresolved (...)` wrapper.
- The renderer MUST NOT make any `IO` call.
- The CLI MUST exit non-zero on output write failure.
- The CLI MUST NOT accept a separate intent file or missing-intent mode;
  the envelope's top-level `intent` is the only source of intent data.
