# Data Model — `report-render`

Tracking issue: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This document captures the new and extended Haskell-side data
shapes the renderer needs. All types live under
`lib/Amaru/Treasury/Report/` and adhere to the constitution's
"pure builders, impure shell" rule (no `IO`).

## Existing types extended

### `Amaru.Treasury.Report.TransactionReport`

One additive optional field. No other field changes.

```haskell
data TransactionReport = TransactionReport
    { trSchema        :: !Int
    , trAction        :: !Text
    , trNetwork       :: !Network
    , trWallet        :: !WalletAccounting
    , trScope         :: !ScopeAccounting
    , trIdentity      :: !TransactionIdentity
    , trMetadata      :: !MetadataSummary
    , trOutputs       :: ![ProducedOutput]
    , trReferenceIns  :: ![UtxoSummary]
    , trSigners       :: ![SignerRequirement]
    , trValidation    :: !ValidationFacts
    , trInlineIntent  :: !(Maybe SomeTreasuryIntent)  -- new, FR-005
    }
```

The encoder emits `intent` only when `trInlineIntent` is `Just`,
matching the additive backwards-compatibility requirement.

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
    , riReport      :: !TransactionReport
    , riInlineIntent :: !(Maybe SomeTreasuryIntent)  -- after CLI override / opt-out
    }
```

### `RenderInputs` and `RenderOutput`

```haskell
data RenderInputs = RenderInputs
    { renderReport     :: !TransactionReport
    , renderIntent     :: !(Maybe SomeTreasuryIntent)
    , renderAddresses  :: !AddressBook
    , renderIdentities :: !IdentityMap
    }

newtype RenderOutput = RenderOutput { unRenderOutput :: Text }
```

The pure renderer has type
`renderReport :: RenderInputs -> RenderOutput`.

### `ReportRenderOpts` (CLI)

```haskell
data ReportRenderOpts = ReportRenderOpts
    { rrInPath       :: !(Maybe FilePath)        -- Nothing = stdin
    , rrOutPath      :: !(Maybe FilePath)        -- Nothing = stdout
    , rrMetadataPath :: !(Maybe FilePath)        -- Nothing = default path if exists
    , rrIntentMode   :: !IntentMode
    }

data IntentMode
    = InlineOrAuto
    -- ^ default: use the report's inline intent if present.
    | IntentOverride !FilePath
    -- ^ --intent PATH: override even if inline is present.
    | NoIntent
    -- ^ --no-intent: opt-out, suppress swap-deal section.
```

`-` is accepted as a stdio alias for `--in` and `--out` and
parsed into `Nothing` (inheriting the default behaviour).

## Resolution priority (FR-014)

`Identity.Resolve.resolveAddress` and `resolveSigner` apply
sources in priority order, returning `Resolved` from the first
match and `Unresolved` if none match:

1. Explicit metadata (`--metadata <path>` or default path).
2. Built-in constants (USDM policy/asset, Sundae pool, Sundae
   protocol fee scripts).
3. Script-hash derivations (Sundae swap-order address parameterised
   by the treasury script hash, registry/permissions/treasury
   deployed-at outputs from the report's reference inputs).
4. Inline intent (operator-wallet address, scope owner key hashes
   for swap intents).
5. `Unresolved` fallback.

Resolution is total. A miss is never a fail; it is an `Unresolved`
that the renderer wraps in `unresolved (<truncated>)`.

## Action-kind classification (FR-019)

The leading section's action label is sourced from
`trAction :: Text`, expected to be one of `swap`, `disburse`,
`withdraw`, `reorganize`, plus an `other` fallback when the JSON
contract recognises an unknown kind. The scope is sourced from:

- the inline intent's `scope.id` when present; otherwise
- the address-book classification of the produced outputs
  (treasury destination → its scope; swap-order destination →
  the parameterising scope); otherwise
- a literal `<unknown scope>` placeholder line.

## Validation rules

- The encoder MUST omit `intent` when `trInlineIntent == Nothing`.
- The renderer MUST NOT emit a bare bech32 or bare 28-byte hex
  without either a label or `unresolved (...)` wrapper.
- The renderer MUST NOT make any `IO` call.
- The CLI MUST exit non-zero on output write failure.
- The CLI MUST honour `--no-intent` even when inline intent is
  present.
- The CLI MUST honour `--intent <path>` even when inline intent is
  present, replacing (not merging) the inline value.
