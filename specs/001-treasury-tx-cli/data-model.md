# Phase 1 Data Model: Treasury Transaction CLI

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-04

This file lists the Haskell types the implementation will introduce
and the relationships between them. It does not commit to internal
function signatures — those land with the implementation PR — but
fixes the *shape* of every value that crosses a module boundary.

## 1. Scopes

```haskell
module Amaru.Treasury.Scope where

data ScopeId
  = CoreDevelopment
  | OpsAndUseCases
  | NetworkCompliance
  | Middleware
  | Contingency
  deriving (Eq, Ord, Show, Read, Bounded, Enum)

scopeText :: ScopeId -> Text
scopeFromText :: Text -> Either String ScopeId
```

- Total parser; rejects unknown scope names.
- `Aeson` instance derives via `Text`.
- `Enum` / `Bounded` lets `optparse-applicative` enumerate valid
  values in `--help`.

## 2. Metadata

```haskell
module Amaru.Treasury.Metadata where

data ScriptRef = ScriptRef
  { scriptHash :: !ScriptHash
  , deployedAt :: !TxIn
  }

data ScopeMetadata = ScopeMetadata
  { smOwner       :: !(Maybe (KeyHash 'Witness))  -- Nothing only for Contingency
  , smAddress     :: !Addr
  , smTreasury    :: !ScriptRef
  , smPermissions :: !ScriptRef
  , smRegistry    :: !ScriptRef
  }

data TreasuryMetadata = TreasuryMetadata
  { tmScopeOwners :: !TxIn
  , tmTreasuries  :: !(Map ScopeId ScopeMetadata)
  }

readMetadataFile :: FilePath -> IO TreasuryMetadata
```

- Parses
  [`journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)
  via Aeson. Validation errors surface with the offending field
  path.
- `deployedAt` strings (`<txid>#<ix>`) are parsed into
  `TxIn = TxIn TxId TxIx`.

## 3. Constants

```haskell
module Amaru.Treasury.Constants where

data Unit = ADA | USDM
  deriving (Eq, Show)

usdmPolicy :: PolicyID
usdmAsset  :: AssetName
```

- `usdmPolicy` and `usdmAsset` are compile-time constants taken
  from
  [`defaults.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/defaults.sh).
- Updated in lockstep when upstream rotates the USDM token.

## 4. Redeemers

```haskell
module Amaru.Treasury.Redeemer where

-- Sundae TreasurySpendRedeemer
data TreasurySpendRedeemer
  = SweepTreasury
  | Reorganize
  | FundIntent       -- not constructed by this CLI
  | DisburseValue !Value

instance ToData TreasurySpendRedeemer  -- hand-written

-- Amaru permissions withdraw-zero redeemer
data PermissionsRedeemer = PermissionsRedeemer
instance ToData PermissionsRedeemer where
  toData _ = List []

-- Treasury withdraw-rewards redeemer
data TreasuryWithdrawRedeemer = TreasuryWithdrawRedeemer
instance ToData TreasuryWithdrawRedeemer where
  toData _ = List []
```

- `ToData` for `DisburseValue` produces
  `Constr 3 [Map [(B policy, Map [(B asset, I qty)])]]`,
  matching [`make_redeemer_disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_disburse.sh).
- `Reorganize` produces `Constr 0 []`.

## 5. Backend

```haskell
module Amaru.Treasury.Backend where

import Cardano.Node.Client.Provider (Provider (..))
type Backend = Provider IO   -- alias only; no new typeclass
```

```haskell
module Amaru.Treasury.Backend.N2C where

mkLocalNodeBackend
  :: FilePath        -- ^ node socket
  -> NetworkMagic
  -> IO Backend
```

- Wraps the `Cardano.Node.Client.N2C.Connection` setup and
  returns the `Provider IO` produced by `mkN2CProvider`.
- All other Backend constructors (Blockfrost, Ogmios+Kupo) live
  in their own modules introduced in follow-up specs.

## 6. Build intents

Each subcommand has its own intent type, parsed once from the CLI
arguments and consumed by the matching `TxBuild` program.

```haskell
module Amaru.Treasury.Tx.Disburse where

data DisburseIntent = DisburseIntent
  { diWallet      :: !Addr
  , diAmount      :: !Integer
  , diUnit        :: !Unit
  , diBeneficiary :: !Addr
  , diScope       :: !ScopeId
  , diWitnesses   :: ![KeyHash 'Witness]
  }

disburseProgram
  :: TreasuryMetadata
  -> DisburseIntent
  -> [TreasuryUtxo]            -- preselected, fee/collateral resolved
  -> SlotNo                    -- ttl
  -> Metadatum                 -- aux data
  -> TxBuild q e ()
```

```haskell
module Amaru.Treasury.Tx.Reorganize where

data ReorganizeIntent = ReorganizeIntent
  { riWallet :: !Addr
  , riAmount :: !Integer
  , riUnit   :: !Unit
  , riScope  :: !ScopeId
  }

reorganizeProgram
  :: TreasuryMetadata
  -> ReorganizeIntent
  -> [TreasuryUtxo]
  -> SlotNo
  -> Metadatum
  -> TxBuild q e ()
```

```haskell
module Amaru.Treasury.Tx.Withdraw where

data WithdrawIntent = WithdrawIntent
  { wiWallet :: !Addr
  , wiScope  :: !ScopeId
  }

withdrawProgram
  :: TreasuryMetadata
  -> WithdrawIntent
  -> WalletUtxo                -- single fuel UTxO
  -> Coin                      -- rewards balance
  -> SlotNo
  -> Metadatum
  -> TxBuild q e ()
```

- `TreasuryUtxo` and `WalletUtxo` are simple newtypes around
  `(TxIn, TxOut ConwayEra)`; defined in `Amaru.Treasury.UtxoSelect`.
- The programs are total; failures (insufficient funds, missing
  scope, etc.) are caught upstream in the runner that resolves
  intents → utxos and only constructs an intent when valid.

## 7. Tx summary

```haskell
module Amaru.Treasury.Summary where

data RedeemerPurpose
  = RpSpend | RpWithdraw | RpMint | RpPublish
  deriving (Eq, Show)

data RedeemerSummary = RedeemerSummary
  { rsPurpose  :: !RedeemerPurpose
  , rsIndex    :: !Word32
  , rsExUnits  :: !ExUnits
  }

data TxSummary = TxSummary
  { tsTxId        :: !TxId
  , tsFeeLovelace :: !Coin
  , tsRedeemers   :: ![RedeemerSummary]
  }

instance ToJSON TxSummary
```

- The encoder produces the shape committed at
  [`contracts/summary-schema.json`](./contracts/summary-schema.json).

## 8. Module dependency graph

```text
Amaru.Treasury.Scope
   ↑                    ↖
Amaru.Treasury.Metadata   Amaru.Treasury.Constants
   ↑                                ↑
   ┌────────────────────────────────┘
   │
Amaru.Treasury.Redeemer
   ↑
Amaru.Treasury.UtxoSelect
   ↑
Amaru.Treasury.Tx.{Disburse,Reorganize,Withdraw}    ← pure, no IO
   ↑
Amaru.Treasury.Summary

Amaru.Treasury.Backend (alias)  ──> Cardano.Node.Client.Provider
Amaru.Treasury.Backend.N2C       ─> Cardano.Node.Client.N2C.Provider

app/.../Main.hs uses everything above; the only IO is in
app/Main.hs and Amaru.Treasury.Backend.N2C.
```
