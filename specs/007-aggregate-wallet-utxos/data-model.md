# Data Model: Aggregate Wallet UTxOs as Fuel

Phase 1 entity definitions. This feature is additive — no entities removed, no field renames.

## Entities

### `WalletSelection` (resolver internal — `lib/Amaru/Treasury/Tx/SwapWizard.hs`)

Today:

```haskell
data WalletSelection = WalletSelection
    { wsTxIn     :: !Text  -- ^ "<txid>#<ix>"
    , wsAddress  :: !Text  -- ^ bech32
    }
```

After:

```haskell
data WalletSelection = WalletSelection
    { wsTxIn        :: !Text   -- ^ head: collateral + first fuel input
    , wsExtraTxIns  :: ![Text] -- ^ additional fuel inputs (largest-first); may be empty
    , wsAddress     :: !Text
    }
```

**Invariants** (enforced by `selectWallet`):

- `wsTxIn` and every member of `wsExtraTxIns` reference pure-ADA UTxOs at `wsAddress`.
- `wsTxIn` is the largest pure-ADA UTxO at the address (i.e. `lovelace(wsTxIn) >= lovelace(x)` for every `x` in `wsExtraTxIns`).
- The cumulative ADA across `wsTxIn ∪ wsExtraTxIns` covers the wallet target (FR-001 + FR-002).
- `wsExtraTxIns` may be empty (single-UTxO degenerate case).

### `WalletJSON` (intent.json wire shape — `lib/Amaru/Treasury/IntentJSON.hs`)

Today:

```haskell
data WalletJSON = WalletJSON
    { wjTxIn    :: !Text
    , wjAddress :: !Text
    }
```

After:

```haskell
data WalletJSON = WalletJSON
    { wjTxIn        :: !Text
    , wjExtraTxIns  :: ![Text]   -- ^ defaults to [] on read
    , wjAddress     :: !Text
    }
```

**Wire format**:

```json
{
  "txIn": "<txid>#<ix>",
  "extraTxIns": ["<txid>#<ix>", "..."],
  "address": "addr1..."
}
```

`extraTxIns` is **always present in newly-emitted intent.json** (canonical `[]` when empty) and **optional on read** (`.!= []` default). Pre-feature intent.json files without the field decode into `wjExtraTxIns = []`.

### `SwapIntent` (typed builder input — `lib/Amaru/Treasury/Tx/Swap.hs`)

Today:

```haskell
data SwapIntent = SwapIntent
    { siWalletUtxo :: !TxIn
    , ...
    }
```

After:

```haskell
data SwapIntent = SwapIntent
    { siWalletUtxo         :: !TxIn      -- ^ head, also collateral
    , siExtraWalletInputs  :: ![TxIn]    -- ^ extras to spend, no collateral
    , ...
    }
```

**Invariant**: `siWalletUtxo ∉ siExtraWalletInputs` (no duplicate).

### `ResolverInput` (resolver call shape — `lib/Amaru/Treasury/Tx/SwapWizard.hs`)

Today:

```haskell
data ResolverInput = ResolverInput
    { riNetwork           :: !Text
    , riWalletAddrBech32  :: !Text
    , riScope             :: !ScopeId
    , riAmountLovelace    :: !Integer
    , riRegistry          :: !RegistryView
    }
```

After:

```haskell
data ResolverInput = ResolverInput
    { riNetwork            :: !Text
    , riWalletAddrBech32   :: !Text
    , riScope              :: !ScopeId
    , riAmountLovelace     :: !Integer
    , riChunkSizeLovelace  :: !Integer  -- ^ NEW: chunk size used for chunkCount
    , riRegistry           :: !RegistryView
    }
```

`riChunkSizeLovelace` lets the resolver compute `chunkCount = ⌈riAmountLovelace / riChunkSizeLovelace⌉` without taking a dependency on `SwapWizardQ` (which is a separate translation-stage input). The CLI passes `chunkSize` already computed in `Main.hs:557`.

### `ResolverError` (resolver failure variants)

Today: 9 constructors. After: 10 — one new variant.

```haskell
data ResolverError
    = ...
    | ResolverWalletShortfall  -- NEW
        !Integer  -- ^ available pure-ADA total at wallet address
        !Integer  -- ^ requested wallet target
```

### `selectWallet` (selection algorithm)

Today:

```haskell
selectWallet :: [(Text, Integer, Bool)] -> Maybe Text
selectWallet inputs = ...   -- returns the largest pure-ADA TxIn or Nothing
```

After:

```haskell
selectWallet
    :: Integer
    -- ^ wallet target lovelace
    -> [(Text, Integer, Bool)]
    -- ^ (txInRef, lovelace, hasNativeAssets)
    -> Either WalletSelectionError ([Text], Integer)
    -- ^ (head : extras, picked sum)

data WalletSelectionError
    = WalletNoPureAda          -- no eligible UTxOs at all
    | WalletShortfall !Integer  -- available
                      !Integer  -- requested
```

The resolver maps `WalletShortfall` to `ResolverWalletShortfall` and `WalletNoPureAda` to either `ResolverEmptyWalletUtxos` (kept) or `ResolverWalletShortfall 0 target` depending on which signal is more useful at the CLI surface (see D6). Returning `Either` instead of `Maybe` lets the resolver discriminate.

## Constants (lib/Amaru/Treasury/Tx/SwapWizard.hs)

```haskell
-- | Slack added to the per-chunk SundaeSwap-deposit obligation when sizing
-- wallet fuel. Covers the on-chain tx fee and the wallet change output's
-- min-UTxO requirement. 2 ADA is empirically sufficient for a Conway-era
-- 10-chunk swap on mainnet (typical fee well under 1 ADA).
walletFeeSlackLovelace :: Integer
walletFeeSlackLovelace = 2_000_000
```

## Trace events (`WizardEvent`)

```haskell
-- before
WeWalletUtxoSelected :: Text -> WizardEvent

-- after
WeWalletUtxoSelected :: Text -> [Text] -> WizardEvent  -- head, extras
```

The human-readable rendering in `prettyWizardEvent` (or whatever the renderer is) becomes `wallet utxo selected: <head> + <N extras>: <ref1>, <ref2>...` so a 0-extras run is indistinguishable in spirit from today's log.
