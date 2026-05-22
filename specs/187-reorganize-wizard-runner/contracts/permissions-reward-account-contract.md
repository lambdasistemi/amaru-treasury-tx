# Contract — `permissionsRewardAccount` derivation

**Slice**: S1 (translator)
**Verdict pinned**: Q-001-B1 (derive from `smPermissions.srHash`
+ network magic; no new metadata field, no new CLI flag).

The reorganize intent's `ReorganizeInputs.permissionsRewardAccount`
field is an `AccountAddress` (bech32 reward account) the
dispatcher (#185) consumes verbatim for the `withdrawScript`
zero-withdrawal entry. The metadata.json file carries only the
permissions script hash (`smPermissions.srHash`); the reward
account must be derived inside `reorganizeToIntent`.

## Derivation

Conceptual:

```text
script-hash : ScriptHash         <-- from smPermissions.srHash
            : 28 bytes (Blake2b-224 of the Plutus script)
network     : Network            <-- from GlobalOpts.goNetworkMagic
                                     resolved at the resolver layer
                                     (always Devnet after the guard)

stake-script credential
  = ScriptHashCredential script-hash
reward-account address
  = mkRewardAccount network stake-script-credential
bech32 render
  = bech32 encode of (network header byte || credential bytes)
```

## Reuse

| Helper | Source | Purpose |
|---|---|---|
| `Amaru.Treasury.Registry.Derive.scriptHashToHex` | already on `main` | already used by sibling translators for the bytes |
| `Cardano.Ledger.Address.mkRewardAccount` | ledger library | the canonical constructor for `AccountAddress` from a network + credential |
| `Amaru.Treasury.IntentJSON.renderRewardAccount` | already on `main` | bech32 render — proves round-trip via the existing `parseRewardAccountBech32` |

The S1 brief instructs the slice executor to **factor out** a
small derivation helper local to `Tx/ReorganizeWizard.hs` (no
new exported function in the registry-derive module) — keeps
the diff small and avoids leaking a wizard concern into a
shared module. The helper signature:

```haskell
derivePermissionsRewardAccount
    :: Network
    -> ScriptHash
    -> Either String AccountAddress
```

`Left e` surfaces a `ReorganizeLedgerFieldParseError
"permissionsRewardAccount" e` at the translator boundary.

## Sanity test (S1 spec)

The happy-path scenario in the new spec MUST include the
derivation as part of the in-memory construction comparison.
The test computes the expected `AccountAddress` value by calling
the same `derivePermissionsRewardAccount` helper on the same
inputs and asserts `Eq` equality with the translator's output —
this is functionally circular but pins the helper's reuse and
prevents drift (renaming the helper without renaming the test
fails the build).

A non-circular round-trip via
`Amaru.Treasury.IntentJSON.parseRewardAccountBech32 ∘
renderRewardAccount === Right` is provided by the existing
IntentJSON spec on `main`; reorganize inherits it for free.

## What this contract does NOT pin

- The exact bech32 hrp encoding — owned by `Cardano.Ledger.Address`
  via `cardano-ledger-conway`. The contract assumes the network
  argument is encoded in the standard ledger way; if upstream
  changes the hrp, all sibling translators would need to update
  together.
- The script-credential vs key-credential discrimination — the
  contract assumes `ScriptHashCredential` always. Plain-key
  treasury permissions are not in scope (the bash recipe doesn't
  produce them).
