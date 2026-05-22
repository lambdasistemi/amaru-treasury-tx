# Contract — Reorganize intent JSON payload

**Slice**: S1 (translator)
**Modules**: `Amaru.Treasury.Tx.ReorganizeWizard` (translator),
`Amaru.Treasury.IntentJSON` (codec — read-only consumer here)

This contract pins the field-by-field mapping from the resolver
output (`ReorganizeEnv` + `ReorganizeWizardAnswers`) to the
intent JSON payload (`SomeTreasuryIntent SReorganize <ti>`)
the dispatcher in #185 consumes.

## Top-level envelope

```haskell
SomeTreasuryIntent SReorganize TreasuryIntent
    { tiSAction = SReorganize
    , tiSchema = 1
    , tiNetwork = reNetwork env                -- "devnet"
    , tiWallet = <WalletJSON>                  -- per below
    , tiScope = <ScopeJSON>                    -- per below
    , tiSigners = [<bech32 of scope-owner key-hash>]
    , tiValidityUpperBoundSlot = reUpperBoundSlot env
    , tiRationale = <RationaleJSON>            -- per below
    , tiPayload = <ReorganizeInputs>           -- per below
    }
```

The dispatcher in `Amaru.Treasury.Build` consumes this via the
existing `decodeTreasuryIntent` + the `SAction Reorganize` arm
(shipped by #185); no change to the dispatcher.

## `tiPayload :: ReorganizeInputs`

Already defined in `Amaru.Treasury.IntentJSON` (shipped by #185).
Field-by-field mapping:

| `ReorganizeInputs` field | Source in this slice |
|---|---|
| `riWalletUtxo :: TxIn` | `rwaFundingSeedTxIn` (operator-typed seed; verbatim per Q-001-C1) |
| `riTreasuryUtxos :: NonEmpty TxIn` | `reTreasuryUtxos env` (sorted by `(TxId, TxIx)` per Q-001-D1; parsed via `txInFromText` in the translator) |
| `riTreasuryAddress :: Addr` | `smAddress (reScopeMetadata env)` (parsed via `parseAddr`) |
| `riTreasuryDeployedAt :: TxIn` | `srDeployedAt (smTreasury (reScopeMetadata env))` (parsed via `parseTxIn`) |
| `riRegistryDeployedAt :: TxIn` | `srDeployedAt (smRegistry (reScopeMetadata env))` (parsed via `parseTxIn`) |
| `riPermissionsRewardAccount :: AccountAddress` | derived from `srHash (smPermissions (reScopeMetadata env))` + network (per Q-001-B1) |
| `riPermissionsDeployedAt :: TxIn` | `srDeployedAt (smPermissions (reScopeMetadata env))` (parsed via `parseTxIn`) |
| `riScopeOwnerSigner :: KeyHash Guard` | `fromJust (smOwner (reScopeMetadata env))` (parsed via `parseGuardKeyHash`; the `fromJust` is safe because the resolver already rejected `Nothing`) |
| `riUpperBound :: SlotNo` | `SlotNo (reUpperBoundSlot env)` |

## `tiWallet :: WalletJSON`

```haskell
WalletJSON
    { wjTxIn = txInText (rwaFundingSeedTxIn ans)
    , wjAddress = wsAddress (reWalletSelection env)   -- bech32 from --wallet-addr
    , wjExtraTxIns = []                                -- reorganize has no extra wallet inputs
    }
```

The `wjAddress` is the operator-typed `--wallet-addr` value (the
resolver's `selectWallet` result preserves it in
`wsAddress`). The `wjTxIn` is the operator-typed
`--funding-seed-txin` rendered as `txid#ix` text. Sibling
stake-reward-init `mkWalletScriptAccount` uses the same shape.

## `tiScope :: ScopeJSON`

Constructed by `mkScopeReorganize env` (see `data-model.md` §7).
The slot carries the per-scope deployment info the dispatcher
uses to look up the build-context: scope id text, treasury
address, treasury UTxO list, deployed-at references for the
three scripts (treasury, permissions, registry), the
permissions reward account bech32, and the scope-owners NFT
reference.

The `sjTreasuryLeftoverLovelace` /
`sjTreasuryLeftoverUsdm` / `sjTreasuryLeftoverOtherAssets`
fields are stamped to zero / `mempty` — those represent the
**preserved-total** which is a chain-context concern owned by
the dispatcher (#185), not by the wizard.

## `tiSigners`

```haskell
tiSigners = [renderGuardKeyHashAsSignerText (fromJust (smOwner scope))]
```

A list with exactly one entry — the scope-owner key hash as it
appears in `--metadata`. The exact text format is the same one
sibling wizards use (`Amaru.Treasury.IntentJSON` has the canonical
renderer; reuse it).

## `tiRationale :: RationaleJSON`

Built by `mkRationaleReorganize ans` (see `data-model.md` §8):

| Field | Source | Constitutional invariant |
|---|---|---|
| `rjEvent` | `fromMaybe "reorganize" (rwaEvent ans)` | MUST be in the closed event enum (Principle VII); the default honors it |
| `rjLabel` | `fromMaybe "reorganize" (rwaLabel ans)` | — |
| `rjDescription` | `fromMaybe "Treasury reorganize: …" (rwaDescription ans)` | — |
| `rjJustification` | `fromMaybe "Routine treasury maintenance" (rwaJustification ans)` | — |
| `rjDestinationLabel` | `fromMaybe "treasury" (rwaDestinationLabel ans)` | — |

## Codec round-trip property (US5)

```haskell
decodeTreasuryIntent (encodeSomeTreasuryIntent intent) === Right intent
```

The S1 spec asserts this via `Eq SomeTreasuryIntent` on a
happy-path scenario. Schema drift (renamed field, changed type
encoding) is the cheapest thing this assertion catches.

## What this contract does NOT pin

- The exact JSON field-name spelling — that's owned by
  `Amaru.Treasury.IntentJSON` (shipped by #185). The contract
  asserts the source-shape mapping; the codec's own tests pin
  the wire-format.
- The CBOR shape after dispatcher → build path — that's owned
  by `Amaru.Treasury.Build.Reorganize` (#185) and proved by the
  existing golden `ReorganizeGoldenSpec`.
- The validity-window semantics — owned by
  `Cardano.Node.Client.Validity`; the resolver consumes
  `ValidityChoice` opaquely.
