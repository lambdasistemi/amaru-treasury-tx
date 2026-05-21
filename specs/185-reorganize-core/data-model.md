# Data Model — `185-reorganize-core`

**Companion to**: [`plan.md`](./plan.md), [`research.md`](./research.md).

This document fixes the typed shapes, JSON shape, and error variants
for the slice. The slice executors implement against this exact
shape unless the orchestrator (attx-185) revises it via a forward
spec/plan correction.

## 1. `ReorganizeInputs` (in `Amaru.Treasury.IntentJSON`)

The JSON payload shape for the `reorganize` arm of
`SomeTreasuryIntent`. Replaces the placeholder
`data ReorganizeInputs = ReorganizeInputs` (lines 540–548).

```haskell
data ReorganizeInputs = ReorganizeInputs
    { riWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , riTreasuryUtxos :: !(NonEmpty TxIn)
    -- ^ N treasury UTxOs to merge into one continuing output;
    -- non-empty by parser invariant (FromJSON rejects an empty
    -- array). All UTxOs must live at @riTreasuryAddress@; this is
    -- enforced at translate time against @ChainContext.ccUtxos@.
    , riTreasuryAddress :: !Addr
    -- ^ destination contract address (also the source — every
    -- treasury UTxO lives here)
    , riTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury-script reference UTxO
    , riRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO (read-only)
    , riPermissionsRewardAccount :: !RewardAccount
    -- ^ Amaru permissions reward account for the withdraw-zero
    -- entry (A1 byte-for-byte parity with upstream bash)
    , riPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions withdrawal-script reference UTxO
    -- (A1 parity)
    , riScopeOwnerSigner :: !(KeyHash Guard)
    -- ^ scope-owner key hash; reorganize.sh's @build_signers@
    -- never appends witnesses for the reorganize action, so this
    -- is one key, not a list
    , riUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }
    deriving stock (Eq, Show)
```

**JSON shape (target):**

```json
{
  "walletUtxo": "<txid64hex>#<ix>",
  "treasuryUtxos": [
    "<txid64hex>#<ix>",
    "<txid64hex>#<ix>"
  ],
  "treasuryAddress": "<bech32 Conway addr>",
  "treasuryDeployedAt": "<txid64hex>#<ix>",
  "registryDeployedAt": "<txid64hex>#<ix>",
  "permissionsRewardAccount": "<bech32 stake addr>",
  "permissionsDeployedAt": "<txid64hex>#<ix>",
  "scopeOwnerSigner": "<28-byte hex>",
  "upperBound": <integer slot>
}
```

Field-name decisions mirror the existing arms (`WithdrawInputs`,
`DisburseInputs`):

- `*Utxo` / `*UtxoS` for `TxIn` references.
- `*DeployedAt` for deployed-script reference UTxOs.
- `*Address` for `Addr` values; `*RewardAccount` for
  `RewardAccount`.
- `*Signer` for `KeyHash Guard` values.
- `upperBound` (integer slot) — same as `WithdrawInputs.wdiUpperBound`.

## 2. `ReorganizeIntent` (in `Amaru.Treasury.Tx.Reorganize`)

The typed lift `translateIntent` produces from `ReorganizeInputs`.
At this slice, the translation is essentially the identity (the
inputs are already ledger types). Future expansion (e.g.
multi-signer support, asset-policy filtering) would diverge the
shapes; for now they match field-by-field.

```haskell
data ReorganizeIntent = ReorganizeIntent
    { rgiWalletUtxo :: !TxIn
    , rgiTreasuryUtxos :: !(NonEmpty TxIn)
    , rgiTreasuryAddress :: !Addr
    , rgiTreasuryDeployedAt :: !TxIn
    , rgiRegistryDeployedAt :: !TxIn
    , rgiPermissionsRewardAccount :: !RewardAccount
    , rgiPermissionsDeployedAt :: !TxIn
    , rgiScopeOwnerSigner :: !(KeyHash Guard)
    , rgiUpperBound :: !SlotNo
    }
    deriving stock (Eq, Show)
```

(Field prefix `rgi` to distinguish from `riXxx` on the inputs and
from `wi` on the withdraw intent.)

## 3. `reorganizeProgram` signature

```haskell
reorganizeProgram
    :: ReorganizeIntent
    -> MaryValue
    -- ^ preserved-total value, computed by the runner from
    --   @ChainContext.ccUtxos@ folded over @rgiTreasuryUtxos@
    -> TxBuild q e ()
```

**Sequence (matches FR-007):**

1. `spend rgiWalletUtxo` → mark as `collateral`.
2. For each `txin` in `rgiTreasuryUtxos`:
   `spendScript txin (RawPlutusData reorganizeRedeemer)`.
3. `reference rgiTreasuryDeployedAt`.
4. `reference rgiRegistryDeployedAt`.
5. `reference rgiPermissionsDeployedAt`.
6. `withdrawScript rgiPermissionsRewardAccount (Coin 0)
   (RawPlutusData emptyListRedeemer)`.
7. `payTo rgiTreasuryAddress <preservedValue>`.
8. `requireSignature rgiScopeOwnerSigner`.
9. `validTo rgiUpperBound`.

## 4. `runReorganizeAction` signature

```haskell
runReorganizeAction
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -- ^ CIP-1694 rationale tree (label 1694)
    -> Addr
    -- ^ change address; also receives @collateral_return@
    -> ExceptT ActionBuildError IO BuildResult
```

**Body shape (high level — slice executor implements):**

1. Collect required UTxOs:
   `[rgiWalletUtxo] ++ toList rgiTreasuryUtxos ++
    [rgiTreasuryDeployedAt, rgiRegistryDeployedAt,
     rgiPermissionsDeployedAt]`.
2. Check all are present in `ccUtxos`; surface `missingUtxosError`
   on absences.
3. **Preserved-value fold** — `foldMap (txOutValue . (ccUtxos !))
   (toList rgiTreasuryUtxos)`.
4. Build evaluator + program; call `TxBuild.build`.
5. Apply `alignCardanoCliBuildFee` post-processing.
6. Run `validateFinalPhase1` (which short-circuits on the
   withdrawals — research §3).
7. Run `ccEvaluateTx` for the script-results map (mirrors
   `runWithdrawAction`).
8. **Exec-units check (FR-015)** — sum the script-results
   `ExUnits`; compare to `ccPParams.maxTxExecutionUnits`; surface
   `DiagnosticExecUnitsExceeded` on overflow.
9. Assemble `BuildResult` with the standard fields.

```haskell
runReorganizeBuild
    :: ChainContext
    -> ReorganizeIntent
    -> Metadatum
    -> Addr
    -> IO BuildResult
runReorganizeBuild ctx intent rationale walletAddr =
    runActionBuild BuildActionReorganize $
        runReorganizeAction ctx intent rationale walletAddr
```

## 5. Error variants (in `Amaru.Treasury.Build.Error.Types`)

**Existing variants reused:**

- `DiagnosticMissingUtxos ![Text]` — for UTxOs not in `ccUtxos`.
- `DiagnosticChecksFailed !Text` — for `validateFinalPhase1`
  failures (rarely fires for reorganize because of the
  withdrawals short-circuit).
- `DiagnosticFeeAlignmentFailed !Text` — for fee-alignment errors.

**New variant added in S2:**

```haskell
| DiagnosticExecUnitsExceeded
    { dxeUsed :: !ExUnits
    , dxeMax  :: !ExUnits
    }
```

**Render line (in `Error/Render.hs`):**

```text
Built transaction exceeds maxTxExecutionUnits: used <mem,steps>, max <mem,steps>.
```

**Action variant — confirm or add in S2:**

`BuildAction` in `Error/Types.hs` carries one constructor per
action arm. If `BuildActionReorganize` is missing, S2 adds it; if
present, S3 just uses it. Slice executor surveys before deciding.

## 6. Fixture layout (in `test/fixtures/reorganize-core/synthetic/`)

Mirrors `test/fixtures/withdraw/synthetic/` (already in tree):

| File | Purpose |
|---|---|
| `answers.json` | Operator-typed answers (treasury UTxO ids, amount/unit, scope) — informational; the test does not consume this, it's documentation of the fixture's provenance. |
| `env.json` | Resolved environment captured at fixture-craft time (network, tip slot, wallet address, validity-hours). Informational. |
| `intent.json` | The canonical `SomeTreasuryIntent` JSON the dispatcher consumes. |
| `utxos.json` | Frozen `ChainContext.ccUtxos` JSON (the synthetic UTxO set). |
| `pparams.json` | Frozen `ChainContext.ccPParams` JSON. |
| `exunits.json` | Pre-recorded `ccEvaluateTx` outcome (the synthetic exec-units the test asserts on). |
| `expected.cbor` | Golden CBOR bytes of the built unsigned tx body. |
| `provenance.md` | Human-readable note documenting where each UTxO / address / key hash came from. |

The fixture set carries TWO treasury UTxOs (the minimum
meaningful N for a "merge" operation). Total values are chosen so:

- `lovelace_1 + lovelace_2 + wallet_fuel ≥ min-utxo + fee + change`
- `usdm_1 + usdm_2 > 0` (so the continuing output carries some USDM
  — exercises the non-empty `MultiAsset` path)
- the resulting tx is well under `maxTxExecutionUnits` (so the
  baseline golden does NOT surface `ExecUnitsExceeded`).

A second fixture variant, `test/fixtures/reorganize-core/synthetic-overflow/`,
carries enough treasury UTxOs that the exec-units sum exceeds a
deliberately small `maxTxExecutionUnits` in its `pparams.json`. The
overflow fixture's test asserts that `runReorganizeBuild` returns
`Left (… DiagnosticExecUnitsExceeded …)`. Same fixture layout, but
`expected.cbor` is absent (the test should fail before serialization).

## 7. Schema delta — `docs/assets/intent-schema.json`

Today the `reorganize` arm is:

```json
"reorganize": {
  "type": "object",
  "additionalProperties": false,
  "properties": {}
}
```

After S1 it becomes:

```json
"reorganize": {
  "type": "object",
  "additionalProperties": false,
  "required": [
    "walletUtxo", "treasuryUtxos", "treasuryAddress",
    "treasuryDeployedAt", "registryDeployedAt",
    "permissionsRewardAccount", "permissionsDeployedAt",
    "scopeOwnerSigner", "upperBound"
  ],
  "properties": {
    "walletUtxo": { "$ref": "#/definitions/TxIn" },
    "treasuryUtxos": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/definitions/TxIn" }
    },
    "treasuryAddress": { "$ref": "#/definitions/Addr" },
    "treasuryDeployedAt": { "$ref": "#/definitions/TxIn" },
    "registryDeployedAt": { "$ref": "#/definitions/TxIn" },
    "permissionsRewardAccount": { "$ref": "#/definitions/RewardAccount" },
    "permissionsDeployedAt": { "$ref": "#/definitions/TxIn" },
    "scopeOwnerSigner": { "$ref": "#/definitions/KeyHashGuard" },
    "upperBound": { "type": "integer", "minimum": 0 }
  }
}
```

Exact shape is generated by `exe:amaru-treasury-intent-schema`;
this section documents the target only. The committed file is
canonical; `just schema-check` enforces it.

## 8. Public API additions (from `lib/`)

**`Amaru.Treasury.Tx.Reorganize`** (replace placeholder):

```haskell
module Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    , reorganizeProgram
    ) where
```

**`Amaru.Treasury.Build.Reorganize`** (new):

```haskell
module Amaru.Treasury.Build.Reorganize
    ( runReorganizeBuild
    , runReorganizeAction
    ) where
```

**`Amaru.Treasury.IntentJSON`** (touch):

- `ReorganizeInputs (..)` is already in the export list (lines
  43–44); the export stays.
- `translateIntent` does not need export changes; the body changes.
- No new exports.

**`Amaru.Treasury.Build`** (touch):

- Add `runReorganizeBuild` to the export list (alongside
  `runDisburse`, `runSwap`, `runSwapCancel`, `runWithdraw` at lines
  37–41).
- Body of `runBuildExcept` changes (the `SReorganize` arm).

## 9. cabal stanza

```cabal
library
    ...
    exposed-modules:
        ...
        Amaru.Treasury.Build.Reorganize
        ...
```

Insert next to `Amaru.Treasury.Build.Withdraw` (alphabetical
ordering of the existing `Build/*` entries).
