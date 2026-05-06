# Phase 0 Research: Unified intent JSON + tx-build

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file resolves the Technical Context unknowns flagged by
`/speckit.plan` and records design decisions whose rationale should
not be discovered later by reading the implementation. Each section
follows the *Decision / Rationale / Alternatives considered* format.

## R1. Tagged union vs sibling records

**Decision**: One top-level
`Amaru.Treasury.IntentJSON.TreasuryIntent` record carrying:

- shared blocks at the top level (`schema`, `action`, `network`,
  `wallet`, `scope`, `signers`, `validityUpperBoundSlot`,
  `rationale`),
- exactly one action-specific payload nested under a key named by
  `action` (`swap` | `disburse` | `withdraw` | `reorganize`).

In Haskell:

```haskell
data TreasuryIntent = TreasuryIntent
    { tiSchema :: !Int            -- 1
    , tiAction :: !Action
    , tiNetwork :: !Text
    , tiWallet :: !WalletJSON
    , tiScope :: !ScopeJSON
    , tiSigners :: ![Text]
    , tiValidityUpperBoundSlot :: !Word64
    , tiRationale :: !RationaleJSON
    , tiPayload :: !ActionPayload
    }

data Action = Swap | Disburse | Withdraw | Reorganize

data ActionPayload
    = SwapPayload SwapInputs
    | DisbursePayload DisburseInputs
    | WithdrawPayload WithdrawInputs
    | ReorganizePayload ReorganizeInputs
```

**Rationale**:

- The `Action` and `ActionPayload` are kept as separate fields
  (rather than a single sum-with-shared-fields) so the FromJSON
  instance can validate the discriminator independently of the
  payload, which gives a better error message for the
  "action says X, payload is Y" mismatch (FR-007).
- Withdraw and reorganize payload types are placeholders until
  features 005 and 006 ship; their FromJSON parsers fail with a
  clear "feature not yet shipped" message.
- Earlier (research §R13 of feature 004) I argued for *sibling*
  records on the grounds that a union forces every consumer to
  pattern-match. That call was wrong: the only consumer is the
  build path, and it has to dispatch on action *anyway*. Sibling
  records just hide the dispatch behind subcommand names while
  duplicating the shared blocks.

**Alternatives considered**:

- **Sibling records (status quo)** — rejected; structurally
  duplicates shared blocks, scatters parser helpers, and lets
  `disburse-wizard | swap` go undetected until the build dies.
- **Phantom-typed shared record** parameterised by action
  (`TreasuryIntent (a :: Action)`) — rejected; the JSON layer is
  un-phantom-typed by the time the parser fires, so the type
  parameter has to be erased anyway, which defeats its purpose.
- **Each variant as an entirely separate top-level record** with
  a discriminator key — rejected; the FromJSON parser would
  need to peek at the discriminator before deciding which record
  to parse, which is more code and a worse error message than
  the chosen design.

## R2. Schema versioning

**Decision**: Top-level `schema :: Int` field. `tx-build`'s
allow-list is `[1]` for v0. An intent with `schema` outside the
allow-list (or with `schema` of the wrong type) fails at parse time
with a clear "unknown intent schema version" error.

**Rationale**:

- Cheap (4 lines of parse code).
- Pays back the first time we change the intent shape after this
  PR ships, because all old binaries refuse to read the new shape
  rather than silently building the wrong tx.
- The wizard always writes `schema: 1` for now.

**Alternatives considered**:

- **No schema field; rely on best-effort parsing** — rejected;
  silent failure mode when a future change is added.
- **Semver-style `"schemaVersion": "1.0"` string** — rejected; an
  integer is enough for our needs and easier to compare.

## R3. Network handling

**Decision**:

- Wizard takes `--network mainnet|preprod|preview` (or
  `--network-magic N` as today). Writes `network: "<name>"` into
  the intent.
- `tx-build` does **not** take any `--network*` flag. It reads
  `network` from the intent and uses the corresponding magic to
  drive the N2C handshake.
- If the N2C handshake reports a magic that differs from
  `intent.network`'s magic, `tx-build` surfaces a typed error
  `"intent declares <X> (magic <Y>), socket is <P> (magic <Q>)"`
  on stderr and exits ≥ 3. This is a tightening of the
  no-redundancy decision per the audit in §R5.

**Rationale**:

- Single source of truth = no operator-visible "which side typed
  the wrong network" failure mode (FR-005, US2).
- The N2C handshake already detects a magic mismatch but reports
  a generic protocol error; surfacing the comparison in our own
  error keeps the failure self-explanatory.

**Alternatives considered**:

- **Keep `--network` as an override for testing** — rejected;
  the audit (§R5) shows there's no legitimate use-case where the
  builder's network would differ from the intent's, and keeping
  the flag preserves the divergence surface.
- **Read `network` from the socket via N2C handshake instead of
  the intent** — rejected; the intent is the wizard's commitment,
  and the build is meant to honour that commitment, not negotiate
  it.

## R4. Module boundary

**Decision**: Four new library modules:

- `Amaru.Treasury.IntentJSON` — `TreasuryIntent`, `Action`,
  `ActionPayload`, `decodeTreasuryIntent`,
  `encodeTreasuryIntent`, `translateTreasuryIntent`,
  `TranslatedTreasuryIntent`.
- `Amaru.Treasury.IntentJSON.Common` — shared parser helpers
  (`parseAddr`, `parseTxIn`, `parseRewardAccount`,
  `parseGuardKeyHash`, `decodeHexBytes`, `mkHash28`, `mkHash32`).
- `Amaru.Treasury.Wizard.Common` — shared signer-resolver
  (`signerScopeFromText`, `normaliseSignerToken`, `isHex28`,
  `ownerForScope`) and the `NetworkConstants` table.
- `Amaru.Treasury.TreasuryBuild` — `runTreasuryBuild ::
  ChainContext -> TreasuryBuildInputs -> IO TreasuryBuildResult`,
  dispatches on the action variant.

Three modules collapse / are removed:

- `Amaru.Treasury.Tx.SwapIntentJSON` — folded into
  `Amaru.Treasury.IntentJSON`.
- `Amaru.Treasury.Tx.SwapBuild` — folded into
  `Amaru.Treasury.TreasuryBuild`.
- `Amaru.Treasury.Tx.Swap.Trace` — folded into a new shared
  `Amaru.Treasury.TreasuryBuild.Trace` (constructors gain an
  action prefix so traces are still distinguishable).

The existing `Amaru.Treasury.Tx.Swap` (pure
[`swapProgram`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Swap.hs))
stays as-is — it's the per-action pure builder and still belongs
under `Tx/`.

`Amaru.Treasury.Tx.SwapWizard` keeps its FromJSON instances and
prompt loop, but imports the shared `IntentJSON.Common` helpers and
the shared `Wizard.Common` resolver instead of defining them
locally.

**Rationale**: matches the "shared structural types up at the top
level, per-action specifics under `Tx/`" pattern. Lets feature 005
(withdraw) and 006 (reorganize) drop their own
`Tx.WithdrawWizard`, `Tx.ReorganizeWizard`, etc. without
duplicating the shared layer.

**Alternatives considered**:

- **Keep `Tx.SwapIntentJSON` as a wrapper around the unified
  `IntentJSON`** — rejected; introduces an unnecessary
  pass-through layer.
- **Inline the shared helpers in `IntentJSON` and don't extract
  `Common`** — rejected; the wizard resolver also needs them
  (specifically `parseAddr` for beneficiary network validation),
  so the shared module pays for itself once we hit two callers.

## R5. CLI audit — what other flags are redundant or dangerous to diverge

This section answers the question raised during planning:
*"Which other arguments are we passing to the tx builder that are
redundant and dangerous to diverge?"*

### Currently on the build side

| Flag | Source of truth | Verdict |
|---|---|---|
| `--network mainnet\|preprod\|preview` | wizard (already in intent as `dijNetwork`) | **redundant + dangerous — primary fix in this PR** |
| `--network-magic WORD32` | same info as `--network`, alternative form | **redundant — drop from builder; keep on wizard as advanced** |
| `--node-socket PATH` (env fallback `CARDANO_NODE_SOCKET_PATH`) | operator-specific; not derivable from intent | **correct, but tightened**: see network-mismatch handling in §R3 |
| `--intent PATH` (or stdin) | I/O routing; no chain semantics | correct |
| `--out PATH` (or stdout) | I/O routing | correct |
| `--log PATH` (or stderr) | I/O routing | correct |
| `--summary-out PATH` (planned for disburse) | I/O routing | correct |

### Already-removed historical risks (spec 001 had these on the build side; we correctly dropped them — confirming they stay out)

- `--metadata PATH` — would let the operator point the build at a
  different metadata.json than the wizard verified. **Stays in
  wizard only.**
- `--ttl-seconds N` — would let the operator override
  `validityUpperBoundSlot` after the wizard wrote it, silently
  shrinking/extending the validity window. **Lives only in
  intent now.**
- `--blacklist-file PATH` / `--exclude TXID#IX` — UTxO-selection
  blacklist; the wizard already applied it before producing the
  intent. Builder running with a different blacklist would either
  reject the wizard's selected UTxOs or silently keep them.
  **Lives only in wizard.**

### Things that look like they could be on the CLI but correctly live in the intent today

- Wallet address + wallet UTxO — in intent.
- Beneficiary address (disburse) — in intent.
- Treasury input set — in intent.
- Reference inputs (4 deployed scripts) — in intent.
- Required signers — in intent.
- Validity upper-bound slot — in intent.
- Rationale fields — in intent.

### Conclusion

The unification's CLI surface for `tx-build` becomes:

```
amaru-treasury-tx tx-build
    [--node-socket PATH]      (or CARDANO_NODE_SOCKET_PATH)
    [--intent PATH]           (defaults to stdin)
    [--out PATH]              (defaults to stdout)
    [--summary-out PATH]      (defaults to <action>.summary.json)
    [--log PATH]              (defaults to stderr)
```

No `--network`. No `--network-magic`. Nothing chain-semantic that
the operator can override; the intent is the sole source of truth.

**One tightening worth noting**: when the N2C handshake reports a
magic that differs from `intent.network`'s magic, surface a typed
error `"intent declares <X> (magic <Y>), socket is <P> (magic
<Q>)"`. Cheap to add (handshake reports the remote magic on
success); turns a confusing protocol error into a clear operator
error.

## R6. Schema migration / backwards compatibility

**Decision**: No silent migration. Old swap intents (no `network`
field, no `schema` field, no top-level `action` field) are rejected
at parse time. Operators re-run the wizard to obtain a v1 intent.

**Rationale**:

- The existing swap intent format was undocumented as a stable
  contract (it was an internal pipe shape between
  `swap-wizard` and `swap`). No published artifact relied on its
  byte shape.
- Silent migration would mask the network/action problem the
  operator should be aware of.
- "Re-run the wizard" is a one-line operator action, given the
  wizard takes flags-only.

**Alternatives considered**:

- **Auto-promote v0 swap intents to v1 by inferring `action: "swap"`
  and reading `network` from the CLI** — rejected; defeats the
  single-source-of-truth principle and creates a permanent legacy
  branch in the parser.

## R7. Testing strategy

**Decision**:

- **Round-trip property** (lands first): for any
  `TreasuryIntent` produced by a small generator across all four
  action variants, `decodeTreasuryIntent .
  encodeTreasuryIntent === Right` (≥100 random shapes; SC-002).
- **Swap golden re-record**: the existing
  [`SwapGoldenSpec`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/golden/SwapGoldenSpec.hs)
  is updated to consume `TreasuryIntent` instead of
  `SwapIntentJSON`. The recorded `expected.cbor` bytes are
  **unchanged** (SC-004 no-behaviour-change gate).
- **Action / payload mismatch** (FR-007): unit test
  `decodeTreasuryIntent` against an intent whose `action` is
  `"swap"` but the JSON contains a `disburse` block. Expect a
  typed error.
- **Schema allow-list** (FR-008): unit test against an intent with
  `schema: 99`. Expect a typed error.
- **Network-mismatch handshake** (R3 + §R5): unit test using a
  stub `Provider IO` that reports a network magic differing from
  `intent.network`. Expect the runner in `Main.hs` to surface the
  typed error.
- **Smoke**: extend
  [`scripts/smoke/swap-wizard-signers`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/scripts/smoke/swap-wizard-signers)
  (or rename to a more general `tx-build-pipe`) to exercise
  `swap-wizard | tx-build`.

**Rationale**: Constitution V (test-first with golden CBOR
fixtures, NON-NEGOTIABLE). The byte-level identity of
`expected.cbor` is the single most important assertion in this
feature — it's what guarantees the unification doesn't change
on-chain shape.

**Alternatives considered**:

- **Re-record `expected.cbor` and accept the new bytes** —
  rejected; that would mask any unintended change and defeat the
  no-behaviour-change gate.

## R8. Feature 002 + Feature 004 doc rebase

**Decision**:

- Feature 002 (swap-wizard) docs land on this PR: spec.md, plan.md,
  quickstart.md, contracts/swap-wizard-cli.md updated in lockstep.
  The 002 spec / quickstart now describes
  `swap-wizard … | tx-build` (was `… | swap`).
- Feature 004 (disburse-wizard) docs **do not** land on this PR.
  PR [#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)
  rebases on top of this once it merges; that rebase commit is
  responsible for updating spec 004 to reference `tx-build`,
  drop the per-action build subcommand from
  [contracts/disburse-cli.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/specs/004-disburse-wizard/contracts/disburse-cli.md),
  and re-record the ada-disburse golden against the new intent
  shape.

**Rationale**: keeps this PR's diff focused and reviewable.
Cross-feature doc updates are a known pain point (see the user
preference about preview-before-merge); doing them in two passes
keeps each rebase mechanical.

**Alternatives considered**:

- **Update both 002 and 004 docs on this PR** — rejected; PR
  diff balloons and reviewer has to context-switch between
  features.
