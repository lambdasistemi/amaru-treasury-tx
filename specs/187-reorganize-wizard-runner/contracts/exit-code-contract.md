# Contract — exit codes for `reorganize-wizard`

**Slices**: S1 (resolver / translator) + S2 (live runner wiring)
**Modules**: `Amaru.Treasury.Cli.ReorganizeWizard` (exitCodeFor),
`Amaru.Treasury.Tx.ReorganizeWizard` (ReorganizeError)

Sibling convention applies: exit `0` on success, `1` for parse
errors (optparse-applicative default), `2` for pre-flight /
configuration / chain-state failures, `3` for runner-body
failures.

## `exitCodeFor` mapping (S2)

```haskell
exitCodeFor :: ReorganizeError -> Int
exitCodeFor = \case
    -- ---- pre-flight tier (exit 2) ----
    ReorganizeOutputParentMissing{} -> 2
    ReorganizeOutputExistsNoForce{} -> 2
    ReorganizeNonDevnetNetwork{} -> 2
    ReorganizeMissingNodeSocket -> 2
    -- ---- resolver / configuration / chain-state tier (exit 2) ----
    ReorganizeMetadataReadError{} -> 2
    ReorganizeScopeNotInMetadata{} -> 2
    ReorganizeScopeOwnerMissing{} -> 2
    ReorganizeInsufficientTreasuryUtxos{} -> 2
    ReorganizeWalletShortfall -> 2
    ReorganizeValidityHoursZero -> 2
    ReorganizeValidityOvershoot{} -> 2
    -- ---- runner-body tier (exit 3) ----
    ReorganizeLedgerFieldParseError{} -> 3
```

## Removed in S2

```haskell
-- ReorganizeTodoSliceC -> 3      -- gone; the stub is gone
```

## Tier rationale

- **Exit 0** — success; intent JSON written to `--out`.
- **Exit 1** — `optparse-applicative` parser failure. Owned by
  the parser, not the runner. No runner code is reached.
- **Exit 2** — operator misconfiguration OR chain state too sparse.
  Resolvable without code change: operator amends a flag, swaps
  metadata, or waits for chain to accumulate UTxOs. The DevNet
  guard, missing socket, missing metadata, wrong scope, missing
  owner, insufficient UTxOs, empty wallet, and bad validity-hours
  all live here.
- **Exit 3** — runner-internal failure. The only variant at this
  tier is `ReorganizeLedgerFieldParseError`, which represents a
  failed parse of a ledger-shaped field constructed by the
  translator (treasury address bech32, scope-owner key hash,
  deployed-at TxIns, derived permissions reward account, or a
  treasury-UTxO row that survived the resolver sort). This
  almost always indicates a malformed `--metadata` file the
  resolver couldn't fully detect, or a chain row in an
  unexpected shape — both are "data on disk / wire is broken",
  not "the operator typed a wrong flag".

## Acceptance scenario coverage

The parser spec
(`test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`)
already pins the exit-code path for `ReorganizeOutputParentMissing`
and `ReorganizeNonDevnetNetwork`. After S2, the same spec pins
`ReorganizeMissingNodeSocket` for the "valid pre-flight, no
socket" cases. The new spec
(`test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs`) pins
every other variant via `Eq` assertions on `Either ReorganizeError
ReorganizeEnv` / `Either ReorganizeError SomeTreasuryIntent` —
indirectly proving the exit-code mapping by pinning the
constructor.

The `exitCodeFor` mapping is asserted directly via a small table
test in the parser spec (one `it` block per variant) — pattern
mirrors the sibling exit-code coverage in
`Cli/ReorganizeWizardParserSpec.hs` lines 290–320.
