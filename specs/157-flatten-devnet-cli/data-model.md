# Data Model: Init Sub-Action Intents

Per `spec.md` refinement (2026-05-17), the three logical init
actions decompose into **seven** CLI-visible sub-action intents,
each with flat action tags and matching Haskell-level structures.

## `Action` (extended)

```haskell
data Action
  = Swap | Disburse | Withdraw | Reorganize
  -- registry-init sub-actions
  | RegistryInitSeedSplit
  | RegistryInitMint
  | RegistryInitReferenceScripts
  -- stake-reward-init sub-actions
  | StakeRewardInitScriptAccount
  | StakeRewardInitPlainAccount
  -- governance-withdrawal-init sub-actions
  | GovernanceWithdrawalInitProposal
  | GovernanceWithdrawalInitMaterialization
  deriving stock (Show, Eq, Ord)
```

Promoted via `-XDataKinds` to index `TreasuryIntent`. `SAction`
gains seven new singletons.

## Per-sub-action input records

Each new sub-action gains an input record whose fields are the
minimal logical inputs the corresponding sub-transaction needs.
Field shapes mirror what the existing `lib/Amaru/Treasury/Devnet/
*Init.hs` library entry passes to its inner build helper. Only the
inputs needed for transaction construction are part of the
intent; submission-only concerns (socket path, wait budget, run
dir) stay out of the intent because the operator's `tx-build` →
`witness` → `submit` cycle owns them per command.

### `RegistryInitSeedSplitInputs`

- `fundingTxIn` — bootstrap funding UTxO id.
- `fundingAddress` — bootstrap funding address (Bech32).
- `seedCount` — number of seed UTxOs to split off.
- `seedLovelace` — lovelace per seed UTxO.
- `network` — must be `devnet` (decoder guard).

### `RegistryInitMintInputs`

- `seedTxIns` — TxIns produced by the seed-split tx (anchors for
  the registry/scopes NFT mint).
- `ownerKeyHash` — registry owner key hash.
- `scriptSet` — derived from `seedTxIns` via the existing
  `deriveDevnetScripts` helper.
- `network` — must be `devnet`.

### `RegistryInitReferenceScriptsInputs`

- `registryDeployedAt` — TxIn for the registry NFT UTxO from the
  mint tx.
- `permissionsScript`, `treasuryScript` — derived from the
  registry mint via existing helpers.
- `fundingTxIn` — funding UTxO for the publication tx.
- `network` — must be `devnet`.

### `StakeRewardInitScriptAccountInputs`

- `registryAnchor` — `RegistryDeployedAt`.
- `permissionsRef` — reference-script TxIn.
- `treasuryRef` — reference-script TxIn.
- `scriptCredential` — script credential for the script reward
  account.
- `fundingTxIn`, `fundingAddress` — funding UTxO + change address.
- `network` — must be `devnet`.

### `StakeRewardInitPlainAccountInputs`

- `plainStakeKeyHash` — verification-key hash for the plain reward
  account.
- `fundingTxIn`, `fundingAddress` — funding UTxO + change address.
- `network` — must be `devnet`.

### `GovernanceWithdrawalInitProposalInputs`

- `treasuryAnchor` — `TreasuryDeployedAt`.
- `withdrawalAmount` — proposed lovelace amount.
- `anchor` — governance anchor (URL + hash).
- `fundingTxIn`, `fundingAddress` — funding UTxO + change address.
- `network` — must be `devnet`.

### `GovernanceWithdrawalInitMaterializationInputs`

- `proposalTxIn` — TxIn for the on-chain governance proposal output.
- `withdrawalScriptCredential`.
- `fundingTxIn`, `fundingAddress`.
- `network` — must be `devnet`.

*(Field names are illustrative; the implementing subagent's brief
freezes the exact name + JSON-key mapping from each library
entry's existing inputs. The orchestrator confirms the mapping at
slice review.)*

## Type families

```haskell
type family Payload (a :: Action) where
  Payload 'Swap = SwapInputs
  Payload 'Disburse = DisburseInputs
  Payload 'Withdraw = WithdrawInputs
  Payload 'Reorganize = ReorganizeInputs
  Payload 'RegistryInitSeedSplit = RegistryInitSeedSplitInputs
  Payload 'RegistryInitMint = RegistryInitMintInputs
  Payload 'RegistryInitReferenceScripts = RegistryInitReferenceScriptsInputs
  Payload 'StakeRewardInitScriptAccount = StakeRewardInitScriptAccountInputs
  Payload 'StakeRewardInitPlainAccount = StakeRewardInitPlainAccountInputs
  Payload 'GovernanceWithdrawalInitProposal = GovernanceWithdrawalInitProposalInputs
  Payload 'GovernanceWithdrawalInitMaterialization = GovernanceWithdrawalInitMaterializationInputs

type family Translated (a :: Action) where
  Translated 'Swap = SwapIntent
  Translated 'Disburse = DisburseIntent
  Translated 'Withdraw = WithdrawIntent
  Translated 'Reorganize = ReorganizeIntent
  -- Each init sub-action translates to a typed input record that
  -- the dispatcher passes straight to the extracted construction
  -- core in lib/Amaru/Treasury/Devnet/*Init.hs.
  Translated 'RegistryInitSeedSplit = RegistryInitSeedSplitTx
  Translated 'RegistryInitMint = RegistryInitMintTx
  Translated 'RegistryInitReferenceScripts = RegistryInitReferenceScriptsTx
  Translated 'StakeRewardInitScriptAccount = StakeRewardInitScriptAccountTx
  Translated 'StakeRewardInitPlainAccount = StakeRewardInitPlainAccountTx
  Translated 'GovernanceWithdrawalInitProposal = GovernanceWithdrawalInitProposalTx
  Translated 'GovernanceWithdrawalInitMaterialization = GovernanceWithdrawalInitMaterializationTx
```

## Validation rules

- Each `FromJSON` instance refuses to decode an intent whose
  `network` field is not `devnet` (decoder guard).
- Round-trip property:
  `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right`
  for every new sub-action.
- The decoder rejects mismatched `action` ↔ `payload` shapes
  (e.g. `"registry-init-seed-split"` with a `RegistryInitMint`
  payload) with a typed error.

## State transitions

None. Each intent is a one-shot description of one unsigned
transaction. The operator's signing / submission cycle owns
sequencing across sub-actions.
