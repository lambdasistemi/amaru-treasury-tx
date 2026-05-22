# Research — `187-reorganize-wizard-runner`

**Feature Branch**: `187-reorganize-wizard-runner`
**Phase**: 0 (Outline & Research)
**Spec**: [`spec.md`](./spec.md)
**Plan**: [`plan.md`](./plan.md)

Each section records: **Decision**, **Rationale**, **Alternatives
considered**. The five Q-001 questions are all approved at their
recommended defaults (A1/B1/C1/D1/E1); the rationale below
documents the supporting evidence the plan adopts.

## 1. Upstream parity mapping (reorganize.sh phases → Haskell runner)

**Decision**: implement the runner as a thin Haskell port of the
seven phases in
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh).
This slice owns four of the seven phases; #185 owns two; #186 owns
one.

| Bash phase | Haskell owner | Notes |
|---|---|---|
| `parse_cli` | `Cli/ReorganizeWizard.reorganizeWizardOptsP` (#186) | optparse-applicative parser shipped by #186 |
| `load_metadata` | `Tx/ReorganizeWizard.resolveReorganize` (S1) | calls `Amaru.Treasury.Metadata.readMetadataFile` via the resolver-env injection |
| `build_signers $metadata $scope` | `Tx/ReorganizeWizard.reorganizeToIntent` (S1) | extracts `smOwner` (scope-owner key hash) from `ScopeMetadata`; bech32-decoded later by the library codec via `parseGuardKeyHash` |
| `resolve_fuel` | `Tx/ReorganizeWizard.resolveReorganize` + `Tx.SwapWizard.selectWallet` (S1) | wallet-addr chain query; informational (Q-001-C1); operator-typed `--funding-seed-txin` is the actual fuel |
| `select_treasury_utxos` | `Tx/ReorganizeWizard.resolveReorganize` (S1) | treasury-address chain query; sort by `(TxId, TxIx)` ascending (Q-001-D1); reject if fewer than 2 |
| `compute_validity_period` | `Tx/ReorganizeWizard.resolveReorganize` + `Cardano.Node.Client.Provider.queryUpperBoundSlot` (S1) | reuse the sibling `ValidityChoice` shape verbatim |
| `make_redeemer_reorganize` | `Amaru.Treasury.Redeemer.reorganizeRedeemer` (#185) | already library; the dispatcher uses it |
| `build_transaction` | `Amaru.Treasury.Build.Reorganize.runReorganizeBuild` (#185) | already library; the dispatcher uses it |
| intent JSON encode + write | `Cli/ReorganizeWizard.runReorganizeWizardEither` (S2) | `encodeSomeTreasuryIntent` + `BSL.writeFile` |

**Rationale**: bash parity is the constitutional invariant
(Principle I); a 1:1 phase mapping makes drift visible at
review-time and keeps the golden CBOR fixtures (Principle V)
honest about which Haskell module owns which bash construct.

**Alternatives considered**:

- **Inlining the resolver into `runReorganizeWizardEither`**:
  shorter, fewer layers, but loses the mock-driven unit-test
  surface (the live-node backend would have to be wrapped
  end-to-end in a record-of-functions, which sibling runners
  have already shown is awkward). Rejected.
- **Splitting the resolver into per-phase functions**: e.g.
  `resolveMetadata`, `resolveWallet`, `resolveTreasury`,
  `resolveValidity`. Easier to test in isolation but explodes
  the public surface; the resolver is internal-glue and the
  sibling pattern is one resolver returning one env. Rejected.

## 2. Resolver shape (record-of-functions vs typeclass)

**Decision**: use the **record-of-functions** pattern shipped by
the sibling `Tx/StakeRewardInitWizard.hs`. The resolver takes a
`ReorganizeResolverEnv m` record carrying four fields:
`sreReadMetadata`, `sreQueryWalletUtxos`, `sreQueryTreasuryUtxos`,
`sreComputeUpperBound`. The resolver itself is
`Monad m => ReorganizeResolverEnv m -> ReorganizeResolverInput ->
m (Either ReorganizeError ReorganizeEnv)`. The unit suite injects
`Identity`-monad mocks.

**Rationale**:

- **Sibling-mirror.** `StakeRewardInitResolverEnv` is the proven
  pattern in this repo (and `RegistryInitResolverEnv` before it).
  Drift here would force a divergent test pattern for #187 alone,
  against the cross-wizard consistency invariant (#189 epic
  carry-forward).
- **Test ergonomics.** Mock effects via record fields are
  trivially overridable per scenario; a typeclass-based
  abstraction would force one global instance per `m` and would
  require `newtype`-wrapping `Identity` per scenario (or `IO`
  with mutable refs). The record approach is cheaper.
- **Constitution Principle II compliance.** The `m` is a type
  parameter; the pure translator is `Identity`-equivalent. The
  live `IO` plumbing is contained in
  `runReorganizeWizardEither`'s body, not in the resolver.

**Alternatives considered**:

- **Typeclass `class HasReorganizeBackend m where readMetadata ::
  …`**: more idiomatic Haskell at the type level, but no
  sibling runner uses this; the project has settled on
  records-of-functions for resolvers. Rejected.
- **`ReaderT (ReorganizeResolverEnv m) m a`**: composes nicely
  but adds a type-level layer the spec doesn't need (the
  resolver makes one set of calls, not a recursive nesting).
  Rejected.

## 3. Mock chain-query rows shape

**Decision**: the chain-query mock returns a flat
`[(Text, Integer, Bool)]` list per address, matching the existing
`Amaru.Treasury.Cli.Common.queryFlat` shape:

- `Text` — the `txid#ix` reference (bech32-style hex);
- `Integer` — lovelace value (for `selectWallet`'s ADA
  sufficiency check);
- `Bool` — whether the UTxO carries any native assets (true →
  excluded from the fuel selection).

**Rationale**: this is the shape the live backend produces (via
`queryFlat`); using it verbatim in the mock means the resolver
plumbing is identical between unit tests and live runs. Sibling
runners (`StakeRewardInitResolverEnv.sreQueryWalletUtxos`) use the
same shape.

**Alternatives considered**:

- **Returning typed `Cardano.Ledger.UTxO`**: more accurate but
  the resolver doesn't yet need ledger-level access (the fuel
  selection is done by `selectWallet` which already accepts the
  flat row shape). Drift would not gain anything here.
  Rejected.

## 4. Typed error placement (`ReorganizeError` extensions)

**Decision**: the new error variants live in
`Amaru.Treasury.Tx.ReorganizeWizard` alongside the existing four
variants (per #186's data-model split: errors in `Tx/`, parser in
`Cli/`). The full extended sum is:

```haskell
data ReorganizeError
    = ReorganizeOutputParentMissing !FilePath        -- #186 (kept)
    | ReorganizeOutputExistsNoForce !FilePath        -- #186 (kept)
    | ReorganizeNonDevnetNetwork !Text               -- #186 (kept)
    | ReorganizeMissingNodeSocket                    -- NEW S2
    | ReorganizeMetadataReadError !String            -- NEW S1
    | ReorganizeScopeNotInMetadata !ScopeId          -- NEW S1
    | ReorganizeScopeOwnerMissing !ScopeId           -- NEW S1
    | ReorganizeInsufficientTreasuryUtxos !Int       -- NEW S1
    | ReorganizeWalletShortfall                      -- NEW S1
    | ReorganizeValidityHoursZero                    -- NEW S1
    | ReorganizeValidityOvershoot !HorizonError      -- NEW S1
    | ReorganizeLedgerFieldParseError !Text !String  -- NEW S1 (field + raw aeson-style msg)
    deriving stock (Eq, Show)
```

`ReorganizeTodoSliceC` is removed in S2 (no longer a sentinel
after the live runner lands).

**Rationale**:

- **Pre-flight / configuration variants at exit code 2**: matches
  the sibling exit-code convention. These represent operator
  misconfiguration (wrong network, missing/garbled metadata,
  not enough treasury UTxOs on the chain).
- **Runner-body variants at exit code 3**: only
  `ReorganizeLedgerFieldParseError` lives at exit 3; it
  represents a runner-internal failure when constructing the
  intent's typed ledger fields (treasury address bech32, owner
  key-hash, deployed-at TxIns, derived reward account). Aligns
  with sibling stake-reward-init's `StakeRewardInitRegistryReadError`
  vs `StakeRewardInitWalletShortfall` tiering.
- **`ReorganizeLedgerFieldParseError !Text !String` shape**: the
  `Text` carries the field name (`"treasuryAddress"`,
  `"scopeOwnerSigner"`, etc.); the `String` carries the aeson /
  bech32 decode message. Mirrors the field-tagging in
  `Amaru.Treasury.IntentJSON.parseLedgerField`.

**Alternatives considered**:

- **One typed variant per field-parse failure**
  (`ReorganizeTreasuryAddressParseError`,
  `ReorganizeOwnerKeyParseError`, …): more precise but
  generates 5-7 variants that all surface at exit 3; the
  spec/golden tests pin the type by field-name string anyway.
  Rejected for compactness.
- **`ReorganizeRunnerBodyError !String` catch-all**: less
  structure; the test suite couldn't pin "this is a ledger-field
  failure vs a non-ledger runner failure". Rejected.

## 5. `permissionsRewardAccount` derivation

**Decision** (Q-001-B1): derive the reward account inside
`reorganizeToIntent` from `smPermissions.srHash` + the resolved
network magic. The derivation is:

```haskell
permissionsRewardAccount :: NetworkId -> ScriptHash -> Text
permissionsRewardAccount net hash = renderRewardAccountBech32 (mkScriptRewardAccount net hash)
```

where `mkScriptRewardAccount` constructs an `AccountAddress` from
the script hash and the network discriminator, and the bech32
render lives next to the existing
`Amaru.Treasury.IntentJSON.renderRewardAccount`.

**Rationale**:

- **Sibling-mirror.** Every other treasury action whose intent
  JSON carries a reward-account field (stake-reward-init,
  withdraw, governance-withdrawal-init) derives it from a script
  hash + the resolved network. The metadata file does NOT carry
  the bech32 reward account; it carries only the script hash.
- **No new flag.** Per Q-001-B's alternative B2, the operator
  would have to type the bech32 — error-prone and against the
  parent-epic "resolver-derived fields" invariant.
- **`renderRewardAccount` already exists** and is the inverse
  of `parseRewardAccountBech32` on the codec side. The
  round-trip (US5) is the unit-level proof.

**Alternatives considered**: see Q-001-B in `spec.md`.

## 6. Treasury-UTxO ordering

**Decision** (Q-001-D1): the resolver sorts the chain-query
result by `(TxId, TxIx)` ascending before constructing the
`NonEmpty TxIn`. The sort comparator is the default `Ord TxIn`
instance from `Cardano.Ledger.TxIn`.

**Rationale**:

- **Determinism.** The chain provider does NOT guarantee a
  stable order across calls; without a sort, two runs against
  the same chain state could produce different JSON bytes.
- **Fixture stability.** Unit tests assert exact JSON bytes (US5
  round-trip + happy-path scenario); a non-deterministic order
  forces fragile set-based assertions.
- **Library-core is order-agnostic.** The dispatcher in #185
  consumes the `NonEmpty TxIn` in list order via `forM_`; the
  ledger canonicalises tx inputs anyway, so the on-chain tx is
  identical regardless of construction order.

**Alternatives considered**:

- **Sort by amount (largest-first)**: more useful for UTxO
  consolidation but introduces a non-trivial decision (what
  measure of "amount" — ADA-only, ADA+USDM, ADA+all assets?).
  Out of scope; defer to a follow-up if operator workflow
  evidence supports it.
- **Provider-order passthrough**: faster (no sort) but
  non-deterministic. Rejected.

## 7. "Compress until full" treasury UTxO selection

**Decision** (Q-001-E1): take **all** UTxOs the treasury-address
chain query returns. No body-size simulation in the wizard;
no `--max-treasury-utxos` flag. The library-core build path
(#185) surfaces the body-size error if the result is too big.

**Rationale**:

- **Bash recipe parity (Principle I).** `reorganize.sh`'s
  `select_treasury_utxos` iterates by appending until the
  estimated body-size exceeds the protocol max. The wizard
  could approximate this with a `cardano-tx-tools` body-size
  estimator, but that's a non-trivial second-call layer.
- **Operator workflow.** The realistic DevNet treasury rarely
  carries enough UTxOs to overflow a body. Mainnet would,
  but mainnet is rejected at the DevNet guard (FR-007). When
  DevNet does overflow, the operator sees the typed
  `BuildSizeOverLimit` from the dispatcher (#185) and re-runs
  after manually pruning.
- **Defer the iterative cap.** A follow-up ticket can implement
  the iterative simulation when operator evidence supports it;
  no ticket is filed in this PR (the spec's Non-Goals section
  documents the deferral).

**Alternatives considered**: see Q-001-E in `spec.md`.

## 8. Live-runner pipeline ordering

**Decision**: the `runReorganizeWizardEither` pipeline runs the
checks in this order (cheap-first):

```text
1. resolveNetworkName / network guard      (string compare)
2. validateOutPath (--out parent + force)  (one filesystem syscall)
3. goSocketPath / ReorganizeMissingNodeSocket  (one record lookup)
4. withLocalNodeBackend (open N2C)        (process / socket open)
5. resolveReorganize:
     a. sreReadMetadata                    (file read + JSON parse)
     b. scope lookup + owner-check         (Map lookup)
     c. sreQueryWalletUtxos                (chain query)
     d. selectWallet                       (pure)
     e. sreQueryTreasuryUtxos              (chain query)
     f. count check (≥ 2)                  (pure)
     g. sreComputeUpperBound               (chain query)
6. reorganizeToIntent                      (pure)
7. encodeSomeTreasuryIntent + writeFile    (BSL.writeFile)
```

**Rationale**: every step that can fail has a cheaper predecessor;
the network guard (string compare) is cheaper than the `--out`
syscall, which is cheaper than the socket open, which is cheaper
than any chain query. Operator typos surface fastest. The
sibling pattern follows the same shape (see `runScriptAccount`).

**Alternatives considered**:

- **Run all the local-only checks in `runReorganizeWizardEither`
  before `withLocalNodeBackend`** (which is what the plan
  already does). Confirmed canonical.
- **Move the `--node-socket` check inside `withLocalNodeBackend`**:
  loses the typed `ReorganizeMissingNodeSocket` error (the
  backend would throw an `IOException`). Rejected for
  testability.

## 9. JSON encode / round-trip

**Decision**: the runner encodes via
`Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent` and writes
the bytes verbatim to `--out`. The round-trip property
(`decodeTreasuryIntent ∘ encodeSomeTreasuryIntent === id`) is
asserted in the S1 spec via `Eq` on `SomeTreasuryIntent`.

**Rationale**:

- The encoder is the canonical library function; the dispatcher
  (#185) consumes the same envelope via `decodeTreasuryIntent`.
- The round-trip assertion is the cheapest schema-drift detector
  (US5 priority).
- The library codec already round-trips for every existing
  `SAction`; the existing `IntentJSONSpec` proves this. The new
  spec adds one more assertion site for the reorganize arm
  (which already has codec coverage from #185; this slice's
  assertion is end-to-end-from-runner, not codec-internal).

**Alternatives considered**:

- **Aeson-pretty / canonical-JSON formatting**: the existing
  encoder uses aeson default formatting (no pretty-printing); the
  dispatcher does not care. Adding canonical-JSON would force a
  schema-bump. Rejected.

## 10. Removing `ReorganizeTodoSliceC`

**Decision**: `ReorganizeTodoSliceC` is removed from
`ReorganizeError` in S2 (the slice that replaces the stub
runner). The two assertions on the variant in the existing
parser spec are updated to assert `ReorganizeMissingNodeSocket`
in the same slice commit (bisect-safe).

**Rationale**: the variant is the spec sentinel for "the stub
runner ran to completion"; once the live runner lands, the
sentinel is obsolete and keeping it would mislead a reader into
thinking a code path still exists that doesn't. The variant has
zero callers after S2.

**Alternatives considered**:

- **Keep `ReorganizeTodoSliceC` as a deprecated alias**:
  no — Haskell has no deprecation for data constructors that
  doesn't trip `-Werror`. Rejected.
- **Rename to `ReorganizeRunnerInternalError`**: would force a
  cross-spec rename without semantic benefit. Rejected.

## NEEDS CLARIFICATION

**None.** All Q-001 questions resolved at A-001-spec-ready
(A1/B1/C1/D1/E1).
