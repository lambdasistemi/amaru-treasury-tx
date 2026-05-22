# Data Model — `187-reorganize-wizard-runner`

**Feature Branch**: `187-reorganize-wizard-runner`
**Phase**: 1 (Design & Contracts)
**Spec**: [`spec.md`](./spec.md)
**Plan**: [`plan.md`](./plan.md)
**Research**: [`research.md`](./research.md)

Typed shapes added by this slice. All new types land in
`lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` alongside the existing
`ReorganizeWizardAnswers` + `ReorganizeError` (shipped by #186).
The parser surface (`ReorganizeWizardOpts`, `CommonFlags`) in
`lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` is unchanged.

## 1. `ReorganizeResolverInput`

The CLI-derived inputs the resolver consumes before chain queries.
Mirrors `StakeRewardInitResolverInput` minus the
`sriRegistryPath` field (reorganize reads metadata.json, not a
per-action registry artifact).

```haskell
data ReorganizeResolverInput = ReorganizeResolverInput
    { rriNetwork :: !Text
    -- ^ CLI @--network@ value. Anything other than @"devnet"@
    --   trips the devnet guard before any chain query.
    , rriWalletAddrBech32 :: !Text
    -- ^ The @--wallet-addr@ flag value (used as the chain-query
    --   address for the wallet UTxO selection).
    , rriMetadataPath :: !FilePath
    -- ^ The @--metadata@ flag value (path to
    --   @journal/2026/metadata.json@).
    , rriScope :: !ScopeId
    -- ^ The @--scope@ flag value (which scope of the treasury
    --   to reorganize).
    , rriValidityHours :: !(Maybe Word16)
    -- ^ The @--validity-hours@ flag value (Nothing → AutoLongest;
    --   Just 0 → ReorganizeValidityHoursZero error).
    }
    deriving stock (Eq, Show)
```

**Construction.** Built in `Cli/ReorganizeWizard.hs` from the
parsed `ReorganizeWizardOpts` + `GlobalOpts` immediately before
`resolveReorganize` is called. No JSON / aeson instance (the
record never escapes the CLI runner shell).

## 2. `ReorganizeError` (extended)

Already shipped by #186 with four variants
(`ReorganizeOutputParentMissing`, `ReorganizeOutputExistsNoForce`,
`ReorganizeNonDevnetNetwork`, `ReorganizeTodoSliceC`). This slice
extends the sum:

```haskell
data ReorganizeError
    = -- | --out's parent directory does not exist; exit 2.
      ReorganizeOutputParentMissing !FilePath
    | -- | --out points at an existing file and --force was not
      --   passed; exit 2.
      ReorganizeOutputExistsNoForce !FilePath
    | -- | --network is not "devnet"; exit 2.
      ReorganizeNonDevnetNetwork !Text
    | -- | --node-socket / CARDANO_NODE_SOCKET_PATH is required
      --   but absent; exit 2. NEW S2.
      ReorganizeMissingNodeSocket
    | -- | --metadata file failed to read or decode; exit 2.
      --   Payload is the raw IOException / aeson decode message.
      --   NEW S1.
      ReorganizeMetadataReadError !String
    | -- | The named --scope is absent from the parsed metadata;
      --   exit 2. NEW S1.
      ReorganizeScopeNotInMetadata !ScopeId
    | -- | The named --scope has owner = null in the metadata
      --   (only contingency may omit owner, but contingency
      --   cannot reorganize); exit 2. NEW S1.
      ReorganizeScopeOwnerMissing !ScopeId
    | -- | The treasury-address chain query returned fewer than
      --   2 UTxOs; exit 2. Payload is the observed count
      --   (0 or 1). NEW S1.
      ReorganizeInsufficientTreasuryUtxos !Int
    | -- | The wallet-addr chain query returned no UTxOs at
      --   all; exit 2. NEW S1.
      ReorganizeWalletShortfall
    | -- | --validity-hours = Just 0; exit 2. NEW S1.
      ReorganizeValidityHoursZero
    | -- | --validity-hours = Just n overshoots the chain
      --   horizon; exit 2. NEW S1.
      ReorganizeValidityOvershoot !HorizonError
    | -- | A ledger-field constructed by the pure translator
      --   failed to parse (treasury address bech32, scope-owner
      --   key hash, deployed-at TxIn, derived permissions reward
      --   account, etc.); exit 3. Payload is (field-name,
      --   raw-decode-message). NEW S1.
      ReorganizeLedgerFieldParseError !Text !String
    deriving stock (Eq, Show)
```

**Removed in S2:** `ReorganizeTodoSliceC` (no longer a sentinel
once the live runner replaces the stub).

**Exit-code tiers** (see
[`contracts/exit-code-contract.md`](./contracts/exit-code-contract.md)):

| Variant | Exit code | Tier |
|---|---|---|
| `ReorganizeOutputParentMissing` | 2 | pre-flight |
| `ReorganizeOutputExistsNoForce` | 2 | pre-flight |
| `ReorganizeNonDevnetNetwork` | 2 | pre-flight |
| `ReorganizeMissingNodeSocket` | 2 | pre-flight |
| `ReorganizeMetadataReadError` | 2 | resolver / configuration |
| `ReorganizeScopeNotInMetadata` | 2 | resolver / configuration |
| `ReorganizeScopeOwnerMissing` | 2 | resolver / configuration |
| `ReorganizeInsufficientTreasuryUtxos` | 2 | resolver / chain state |
| `ReorganizeWalletShortfall` | 2 | resolver / chain state |
| `ReorganizeValidityHoursZero` | 2 | resolver / configuration |
| `ReorganizeValidityOvershoot` | 2 | resolver / chain state |
| `ReorganizeLedgerFieldParseError` | 3 | runner-body |

## 3. `ReorganizeResolverEnv m`

The record-of-functions abstracting chain effects. Tests inject
mocks; the live runner wires to `Cardano.Node.Client.Provider`.

```haskell
data ReorganizeResolverEnv m = ReorganizeResolverEnv
    { sreReadMetadata
        :: !(FilePath -> m (Either String TreasuryMetadata))
    -- ^ Read + decode the --metadata file. The live wiring
    --   wraps 'Amaru.Treasury.Metadata.readMetadataFile' with an
    --   IOException catcher (mirrors 'readRegistrySafely' in
    --   sibling Cli/StakeRewardInitWizard.hs).
    , sreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ (txInRef, lovelace, hasNativeAssets) for the
    --   --wallet-addr address. Used by 'selectWallet' for the
    --   informational wallet selection.
    , sreQueryTreasuryUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ (txInRef, lovelace, hasNativeAssets) for the scope's
    --   treasury address. Used to pick the UTxOs to merge.
    , sreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    -- ^ Sample the chain tip + add --validity-hours; matches the
    --   sibling 'Cardano.Node.Client.Provider.queryUpperBoundSlot'
    --   signature.
    }
```

**Construction.**

- **Tests** build a value with `Identity`-monadic fields whose
  bodies return canned results per scenario. Pattern mirrors
  `StakeRewardInitResolverEnv` mocking in
  `test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs`.
- **Live runner** builds a value inside `withLocalNodeBackend`
  with:
  - `sreReadMetadata = readMetadataSafely` (a new thin wrapper
    around `Metadata.readMetadataFile` that converts
    `IOException` to `Left String` — mirrors `readRegistrySafely`);
  - `sreQueryWalletUtxos = queryFlat backend` (reuses
    `Cli/Common.queryFlat` — the same call used by the sibling);
  - `sreQueryTreasuryUtxos = queryFlat backend` (same shape;
    different address argument);
  - `sreComputeUpperBound = \choice -> fmap (fmap unwrapSlot) <$>
    queryUpperBoundSlot backend choice` (verbatim from the
    sibling).

## 4. `ReorganizeEnv`

The resolved environment the pure translator consumes. Carries
everything `reorganizeToIntent` needs to construct a
`SomeTreasuryIntent SReorganize <ti>` value.

```haskell
data ReorganizeEnv = ReorganizeEnv
    { reNetwork :: !Text
    -- ^ Always "devnet" after the resolver guard. Stamped into
    --   'TreasuryIntent.tiNetwork' verbatim.
    , reUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied invalid-hereafter slot. Already
    --   horizon-validated.
    , reMetadata :: !TreasuryMetadata
    -- ^ Parsed --metadata file (full); needed for the
    --   wallet block and the deployed-at references for the
    --   named scope.
    , reScopeMetadata :: !ScopeMetadata
    -- ^ The named scope's per-scope deployment (treasury_script,
    --   permissions_script, registry_script, address, owner).
    , reWalletSelection :: !WalletSelection
    -- ^ Informational wallet selection from
    --   'selectWallet'. The 'wsTxIn' field is OVERRIDDEN by the
    --   operator-typed --funding-seed-txin per Q-001-C1; only
    --   the 'wsAddress' is consumed by the translator. (The
    --   'wsExtraTxIns' field is empty for reorganize.)
    , reTreasuryUtxos :: !(NonEmpty Text)
    -- ^ Selected treasury UTxOs (txid#ix references), sorted by
    --   (TxId, TxIx) ascending per Q-001-D1. The translator
    --   parses each via 'parseTxIn' inside
    --   'reorganizeToIntent' (any parse failure surfaces
    --   'ReorganizeLedgerFieldParseError "treasuryUtxos" _').
    }
    deriving stock (Eq, Show)
```

**Construction.** Returned by `resolveReorganize` on success.
The resolver does not parse `reTreasuryUtxos` into ledger `TxIn`
values — that is the translator's responsibility (so a
chain-side row with a malformed `txid#ix` surfaces a typed
parse error inside `reorganizeToIntent`, not silently).

## 5. `resolveReorganize`

Signature:

```haskell
resolveReorganize
    :: (Monad m)
    => ReorganizeResolverEnv m
    -> ReorganizeResolverInput
    -> m (Either ReorganizeError ReorganizeEnv)
```

**Pipeline** (in this order):

1. **Devnet guard.** If `rriNetwork ≠ "devnet"`, return
   `Left (ReorganizeNonDevnetNetwork rriNetwork)` immediately.
   No other effect.
2. **Metadata read.** `sreReadMetadata rriMetadataPath`. On
   `Left e`, return `Left (ReorganizeMetadataReadError e)`. No
   wallet/treasury query.
3. **Scope lookup.** `Map.lookup rriScope (tmTreasuries
   metadata)`. On `Nothing`, return
   `Left (ReorganizeScopeNotInMetadata rriScope)`.
4. **Scope-owner check.** If `smOwner scope = Nothing`, return
   `Left (ReorganizeScopeOwnerMissing rriScope)`. (Only
   contingency may omit owner; contingency cannot reorganize.)
5. **Wallet query.** `sreQueryWalletUtxos rriWalletAddrBech32`.
   Pipe the result through `selectWallet 1`. On `Left _` or
   `Right ([], _)`, return `Left ReorganizeWalletShortfall`.
6. **Treasury query.** `sreQueryTreasuryUtxos (smAddress scope)`.
   Count the rows; if `< 2`, return
   `Left (ReorganizeInsufficientTreasuryUtxos count)`.
7. **Sort + non-empty.** Sort the result by `(TxId, TxIx)`
   ascending (parse each row's `txid#ix` text to compare; on
   parse failure return
   `Left (ReorganizeLedgerFieldParseError "treasuryUtxos" _)`).
   The result is `NonEmpty Text` (count ≥ 2).
8. **Upper-bound.** Run `resolveUpperBound sreComputeUpperBound
   rriValidityHours`. On `Left e`, return the typed error
   (`ValidityHoursZero` or `ValidityOvershoot`).
9. **Assemble.** Return `Right ReorganizeEnv{…}`.

**Carry-forward of NFR-006 (subcommand independence)**: the
resolver does not branch on any sibling action's state or run
any sibling check. Reorganize is per-scope; the resolver
consumes the named `--scope` only.

## 6. `reorganizeToIntent`

Signature:

```haskell
reorganizeToIntent
    :: ReorganizeEnv
    -> ReorganizeWizardAnswers
    -> Either ReorganizeError SomeTreasuryIntent
```

**Pure**. Constructs the
`SomeTreasuryIntent SReorganize <TreasuryIntent>` value:

1. Defensive guard: if `rwaValidityHours = Just 0`, return
   `Left ReorganizeValidityHoursZero` (mirrors the sibling
   translator).
2. Parse each `reTreasuryUtxos` text into a ledger `TxIn` (via
   `Amaru.Treasury.LedgerParse.txInFromText`). Any parse failure
   surfaces
   `Left (ReorganizeLedgerFieldParseError "treasuryUtxos<n>" e)`
   carrying the row index.
3. Parse the scope owner: `parseGuardKeyHash (fromJust (smOwner
   scope))` (the `fromJust` is safe because the resolver
   already rejected `Nothing`). On parse failure, surface
   `Left (ReorganizeLedgerFieldParseError "scopeOwnerSigner" e)`.
4. Parse the treasury address: `parseAddr (smAddress scope)`.
5. Parse each deployed-at TxIn:
   `parseTxIn (srDeployedAt (smTreasury scope))`,
   `parseTxIn (srDeployedAt (smRegistry scope))`,
   `parseTxIn (srDeployedAt (smPermissions scope))`.
6. Derive the permissions reward account: bech32 of
   `mkScriptRewardAccount net (srHash (smPermissions scope))`.
   On bech32 derivation failure, surface
   `Left (ReorganizeLedgerFieldParseError "permissionsRewardAccount" e)`.
7. Construct the JSON-shaped intent:

```haskell
let intent =
        TreasuryIntent
            { tiSAction = SReorganize
            , tiSchema = 1
            , tiNetwork = reNetwork env       -- "devnet"
            , tiWallet =
                WalletJSON
                    { wjTxIn = txInText (rwaFundingSeedTxIn ans)
                    , wjAddress = wsAddress (reWalletSelection env)
                    , wjExtraTxIns = []
                    }
            , tiScope = mkScopeReorganize env
            , tiSigners = [<bech32 of the scope-owner key-hash>]
            , tiValidityUpperBoundSlot = reUpperBoundSlot env
            , tiRationale = mkRationaleReorganize ans
            , tiPayload =
                ReorganizeInputs
                    { riWalletUtxo = rwaFundingSeedTxIn ans
                    , riTreasuryUtxos = <parsed + sorted list>
                    , riTreasuryAddress = <parsed addr>
                    , riTreasuryDeployedAt = <parsed treasury TxIn>
                    , riRegistryDeployedAt = <parsed registry TxIn>
                    , riPermissionsRewardAccount = <derived AccountAddress>
                    , riPermissionsDeployedAt = <parsed permissions TxIn>
                    , riScopeOwnerSigner = <parsed owner KeyHash>
                    , riUpperBound = SlotNo (reUpperBoundSlot env)
                    }
            }
in  Right (SomeTreasuryIntent SReorganize intent)
```

The exact constructor names for the parsed types come from
`Amaru.Treasury.IntentJSON`; the contract pins the exact field
mapping (see
[`contracts/intent-payload-contract.md`](./contracts/intent-payload-contract.md)).

## 7. Per-scope JSON skeleton (`mkScopeReorganize`)

Constructed inside `reorganizeToIntent`. The `ScopeJSON` slot of
the `TreasuryIntent` carries the per-scope deployment info the
dispatcher in #185 uses to look up the build-context. The
skeleton mirrors `mkScopeStakeRewardInit` from the sibling but
substitutes the real (not placeholder) values, because reorganize
binds to a real scope (vs stake-reward-init's "top-level
credential" placeholder).

```haskell
mkScopeReorganize :: ReorganizeEnv -> ScopeJSON
mkScopeReorganize env =
    let scope = reScopeMetadata env
    in  ScopeJSON
            { sjId = scopeIdText (reScope env)
            , sjTreasuryAddress = smAddress scope
            , sjTreasuryUtxos = NE.toList (reTreasuryUtxos env)
            , sjTreasuryLeftoverLovelace = 0
            -- ^ The translator does not compute the preserved
            --   total — that's a chain-context concern owned by
            --   the dispatcher / build path (#185). The codec
            --   field is informational here.
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = srHash (smTreasury scope)
            , sjPermissionsRewardAccount =
                <derived bech32 as in section 6>
            , sjScopesDeployedAt = tmScopeOwners (reMetadata env)
            , sjPermissionsDeployedAt = srDeployedAt (smPermissions scope)
            , sjTreasuryDeployedAt = srDeployedAt (smTreasury scope)
            , sjRegistryDeployedAt = srDeployedAt (smRegistry scope)
            , sjRegistryPolicyId = srHash (smRegistry scope)
            }
```

(Field names approximate; the contract document pins the exact
shape.)

## 8. Rationale block (`mkRationaleReorganize`)

The runner copies the operator-typed `rwa*` rationale overrides
verbatim, defaulting to constitutional-bash-parity values when
absent:

```haskell
mkRationaleReorganize :: ReorganizeWizardAnswers -> RationaleJSON
mkRationaleReorganize ans =
    RationaleJSON
        { rjEvent =
            fromMaybe "reorganize" (rwaEvent ans)
        , rjLabel =
            fromMaybe "reorganize" (rwaLabel ans)
        , rjDescription =
            fromMaybe "Treasury reorganize: merge treasury UTxOs into one continuing output" (rwaDescription ans)
        , rjJustification =
            fromMaybe "Routine treasury maintenance" (rwaJustification ans)
        , rjDestinationLabel =
            fromMaybe "treasury" (rwaDestinationLabel ans)
        }
```

The constitutional `event` enum (Principle VII) requires
`"reorganize"`; the default honors it. Operators may override
each field; the constitutional invariant is that a non-default
`--event` MUST still be in the closed list. Validation of
override values is **out of scope for this slice** (no sibling
wizard validates it either; the SundaeSwap indexer is the
downstream verifier).

## 9. Existing types (unchanged)

- `ReorganizeWizardAnswers` (#186) — operator-typed answers. No
  shape changes. The translator consumes
  `rwaFundingSeedTxIn` (the fuel UTxO),
  `rwaWalletAddr`, `rwaMetadataPath`, `rwaScope`,
  `rwaValidityHours`, and the rationale overrides.
- `ReorganizeWizardOpts`, `CommonFlags` (#186) — parser types.
  Unchanged.
- `TreasuryMetadata`, `ScopeMetadata`, `ScriptRef` (Metadata.hs)
  — already shipped on `main`. The runner consumes them
  read-only.
- `WalletSelection` (Tx/SwapWizard.hs) — already shipped. The
  resolver constructs one from the wallet-addr query + the
  operator-typed funding seed.

## 10. Validation rules

| Field | Rule | On failure |
|---|---|---|
| `rriNetwork` | must equal `"devnet"` | `ReorganizeNonDevnetNetwork` |
| `rriMetadataPath` | file exists + decodes as `TreasuryMetadata` | `ReorganizeMetadataReadError` |
| `rriScope` | key present in `tmTreasuries` | `ReorganizeScopeNotInMetadata` |
| `smOwner` for `rriScope` | `Just _` | `ReorganizeScopeOwnerMissing` |
| wallet query at `rriWalletAddrBech32` | returns at least 1 row | `ReorganizeWalletShortfall` |
| treasury query at `smAddress` | returns ≥ 2 rows | `ReorganizeInsufficientTreasuryUtxos n` |
| `rriValidityHours` | not `Just 0` | `ReorganizeValidityHoursZero` |
| upper-bound resolver | returns `Right slot` | `ReorganizeValidityOvershoot e` |
| all ledger-field parses | succeed | `ReorganizeLedgerFieldParseError field msg` |

## 11. State transitions

None. The runner is stateless per invocation; no resumable state
(parked under #163).
