# Data Model — `186-reorganize-wizard-parser`

This document pins the typed shapes that the parser scaffold
introduces. The exact Haskell record/sum syntax is illustrative
— slice executors may tweak field naming so long as the
acceptance scenarios in `spec.md` and the contracts under
[`contracts/`](./contracts/) still hold.

## 1. `ReorganizeWizardOpts` (in `Cli.ReorganizeWizard`)

The optparse-applicative output record. Carries every operator-typed
flag value at the CLI surface.

```haskell
-- Common flag block, sibling-mirrored (B1 verdict).
data CommonFlags = CommonFlags
    { cfWalletAddr      :: !Text
    , cfMetadataPath    :: !FilePath
    , cfOut             :: !FilePath
    , cfLog             :: !(Maybe FilePath)
    , cfScope           :: !ScopeId
    , cfValidityHours   :: !(Maybe Word16)
    , cfDescription     :: !(Maybe Text)   -- rationale
    , cfJustification   :: !(Maybe Text)   -- rationale
    , cfDestinationLabel:: !(Maybe Text)   -- rationale
    , cfEvent           :: !(Maybe Text)   -- rationale
    , cfLabel           :: !(Maybe Text)   -- rationale
    , cfForce           :: !Bool
    }
    deriving stock (Eq, Show)

-- Reorganize wizard has no sub-actions (see research.md §2).
data ReorganizeWizardOpts = ReorganizeWizardOpts
    { rwoCommon         :: !CommonFlags
    , rwoFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)
```

**Notes**:

- `cfScope` uses `Amaru.Treasury.Scope.ScopeId` (sibling-mirror
  via `scopeReader`).
- `rwoFundingSeedTxIn` is parsed by an `eitherReader` over
  `Amaru.Treasury.LedgerParse.txInFromText` (FR-006).
- No `cfBootstrap` flag (reorganize has no bootstrap-mode
  branch — bootstrap-mode is registry-init-wizard's #175 concern).
- No `cfNetwork` field; `--network` is global (see research.md §5).

## 2. `ReorganizeWizardAnswers` (in `Tx.ReorganizeWizard`)

The typed answers record the runner consumes — the
"interview answers" view of `ReorganizeWizardOpts`. Carries the
same operator-typed values but with rationale overrides
absorbed and `cfForce` / `cfLog` / `cfOut` dropped (those are
runner-shell concerns, not "answers").

```haskell
data ReorganizeWizardAnswers = ReorganizeWizardAnswers
    { rwaWalletAddr      :: !Text
    , rwaMetadataPath    :: !FilePath
    , rwaScope           :: !ScopeId
    , rwaValidityHours   :: !(Maybe Word16)
    , rwaDescription     :: !(Maybe Text)
    , rwaJustification   :: !(Maybe Text)
    , rwaDestinationLabel:: !(Maybe Text)
    , rwaEvent           :: !(Maybe Text)
    , rwaLabel           :: !(Maybe Text)
    , rwaFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)
```

The `Opts → Answers` projection (`opsToAnswers :: ReorganizeWizardOpts
-> ReorganizeWizardAnswers`) is shipped in `Tx.ReorganizeWizard`
so the parser stays Cli-only and the runner stays Tx-only
(sibling convention from `Tx.RegistryInitWizard`).

**This slice does not yet use `ReorganizeWizardAnswers`** —
the stub runner has no body that consumes it. The record is
shipped here so #187's runner can consume it without churning
the public module surface. Plan reviewer note: this is a
"shipped early, used at #187" record; #187's brief will reference
this exact shape.

## 3. `ReorganizeError` (in `Tx.ReorganizeWizard`)

The typed error sum surfaced by the runner. Each variant maps
to a CLI exit code via the `exitCodeFor` helper in the runner
module.

```haskell
data ReorganizeError
    = ReorganizeOutputParentMissing FilePath
      -- ^ --out's parent directory does not exist; exit 2
    | ReorganizeOutputExistsNoForce FilePath
      -- ^ --out points at an existing file and --force was not passed; exit 2
    | ReorganizeNonDevnetNetwork Text
      -- ^ --network is not "devnet" (C2 verdict); exit 2
    | ReorganizeTodoSliceC
      -- ^ stub: real runner body lands in #187 (Slice C); exit 3
    deriving stock (Eq, Show)
```

**Notes**:

- `ReorganizeNonDevnetNetwork` carries the offending network
  name as `Text` so test specs can assert the exact value
  (mirroring `RegistryInitNonDevnetNetwork`).
- `ReorganizeTodoSliceC` is a nullary constructor — no payload
  needed; the constructor name is the marker.
- `ReorganizeError` derives `Show` so the runner can
  `hPrint stderr e` (matching sibling pattern).
- #187 will grow this sum with the runner-body error variants
  (chain query failure, missing UTxO, validity-bound
  computation failure, etc.).

## 4. Flag → ReadM mapping (informative; full contract under [`contracts/parser-flag-contract.md`](./contracts/parser-flag-contract.md))

| Flag | Required | ReadM | Backing helper |
|---|---|---|---|
| `--wallet-addr` | yes | `strOption` | `Text` literal (validation happens at #187's runner) |
| `--metadata` | yes | `strOption` | `FilePath` literal |
| `--out` / `-o` | yes | `strOption` | `FilePath` literal; pre-flight via `validateOutPath` |
| `--log` | no | `strOption` (wrapped in `optional`) | `FilePath` literal |
| `--scope` | yes | `eitherReader scopeFromText . toLower` | `Amaru.Treasury.Scope.scopeFromText` |
| `--validity-hours` | no | `option auto` (wrapped in `optional`) | `Word16` |
| `--description` | no | `strOption` (wrapped in `optional`) | rationale `Text` |
| `--justification` | no | `strOption` (wrapped in `optional`) | rationale `Text` |
| `--destination-label` | no | `strOption` (wrapped in `optional`) | rationale `Text` |
| `--event` | no | `strOption` (wrapped in `optional`) | rationale `Text` |
| `--label` | no | `strOption` (wrapped in `optional`) | rationale `Text` |
| `--force` | no | `flag False True` | `Bool` |
| `--funding-seed-txin` | yes | `eitherReader (txInFromText . T.pack)` | `Amaru.Treasury.LedgerParse.txInFromText` |

`--network` is NOT a wizard-subcommand flag (see research.md §5);
it is parsed by the global `globalOptsP` and resolved via
`resolveNetworkName g`.

## 5. State transitions

The parser/stub-runner pipeline:

```
                          ┌─────────────────────────────────────┐
                          │ optparse-applicative parser         │
argv  ─────────────────►  │ reorganizeWizardOptsP               │
                          └─┬───────────────────────────────────┘
                            │
                  ┌─────────┴─── Failure ParserFailure  → exit 1
                  │
                  ▼ Success ReorganizeWizardOpts
                          ┌─────────────────────────────────────┐
                          │ runReorganizeWizard / Either helper │
                          ├─────────────────────────────────────┤
                          │ Step 1: --network devnet pre-flight │
                          │         resolveNetworkName g        │
                          │         Right "devnet"   ─► continue │
                          │         _                ─► exit 2  │ ◄── ReorganizeNonDevnetNetwork
                          ├─────────────────────────────────────┤
                          │ Step 2: --out parent-dir pre-flight │
                          │         validateOutPath path force  │
                          │         Right ()         ─► continue │
                          │         Left _           ─► exit 2  │ ◄── Reorganize{OutputParentMissing,OutputExistsNoForce}
                          ├─────────────────────────────────────┤
                          │ Step 3: stub runner body            │
                          │         hPrint ReorganizeTodoSliceC │
                          │         exit 3                      │ ◄── ReorganizeTodoSliceC
                          └─────────────────────────────────────┘
```

No state is mutated; no file is written; no socket is opened
on any error path. The success path of this slice never reaches
the live runner body (#187's concern).

## 6. JSON shapes

**None.** This slice introduces no new JSON shape. The
`ReorganizeInputs` JSON shape is already shipped by #185 (the
library core). The runner body in #187 will write
`SomeTreasuryIntent SReorganize ReorganizeInputs` to
`--out` using the existing
`Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent`. This slice
does not touch JSON encoding.

## 7. Cabal module exposure

`amaru-treasury-tx.cabal` adds two lines to the `library`
stanza's `exposed-modules` list (alphabetically ordered):

```
exposed-modules:
    ...
    Amaru.Treasury.Cli.ReorganizeWizard
    ...
    Amaru.Treasury.Tx.ReorganizeWizard
    ...
```

The exact insertion point is determined by alphabetical ordering
against the existing list:

- `Amaru.Treasury.Cli.ReorganizeWizard` inserts between
  `Amaru.Treasury.Cli.RegistryInitWizard` and
  `Amaru.Treasury.Cli.ReportRender` (alphabetical: Reg < Reor <
  Repo, where Reor < Repo because 'o' < 'p').
- `Amaru.Treasury.Tx.ReorganizeWizard` inserts between
  `Amaru.Treasury.Tx.Reorganize` and
  `Amaru.Treasury.Tx.StakeRewardInitWizard` (alphabetical:
  Reorganize < ReorganizeWizard < StakeRewardInitWizard).
