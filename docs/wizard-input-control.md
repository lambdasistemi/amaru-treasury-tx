# Operator wizard input control (`--exclude-utxo` / `--extra-tx-in`)

Every Amaru treasury wizard that does wallet (or per-unit treasury)
UTxO selection accepts two paired CLI flags for explicit operator
control over the candidate pool:

- `--exclude-utxo TX_HASH#IX` — filter a specific outref out of the
  candidate set BEFORE the wizard runs its selection.
- `--extra-tx-in TX_HASH#IX` — force a specific outref to land in the
  emitted intent's `wallet.extraTxIns` array (in addition to the
  primary `wallet.txIn` the wizard picks).

Both flags are repeatable, and both validate the outref at parse time
(64-char lowercase hex `TX_HASH` + `#` + non-negative integer index).
Passing the same outref to both flags on the same wizard invocation
is a structured error reported BEFORE any chain query — see
**Contradictory inclusion/exclusion** below.

Wizards in scope (every wizard that touches a wallet or per-unit
treasury candidate pool):

- `swap-wizard`
- `disburse-wizard`
- `contingency-disburse-wizard`
- `withdraw-wizard`
- `registry-init-wizard` (all four sub-actions)
- `stake-reward-init-wizard` (both sub-actions)
- `governance-withdrawal-init-wizard` (both sub-actions)
- `reorganize-wizard` (wallet pool only; treasury inputs are
  metadata-driven, not selection-driven)

## Why this exists

Every wizard's `selectWallet` (and equivalent treasury-selection path)
picks UTxOs from a fresh chain query, biggest-pure-ADA first. Before
these flags, the operator's only escape was to run the wizard, then
hand-edit `intent.json` (`.wallet.txIn` and `.wallet.extraTxIns`)
before `tx-build` — which defeats the wizard's purpose of producing
a typed, byte-stable intent.

Three concrete cases:

1. **Pending multi-sig collision** — a wallet UTxO is referenced by
   an in-flight build still collecting signatures. Submitting a
   second build will race the first; the loser fails phase-2.
   `--exclude-utxo` keeps that specific UTxO out of the second
   wizard run.
2. **Reserving a UTxO for a parallel flow** — operator has four
   wallet UTxOs and wants three of them in this build, the fourth
   held back for an imminent contingency action that hasn't built
   yet.
3. **Working around a damaged UTxO** — UTxO is at the right address
   but operationally unspendable (asset the wizard's downstream
   logic can't handle, marked-stale reference input, etc.).

See [#184](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184)
for the original incident.

## Format

`TX_HASH#IX` where:

- `TX_HASH` is exactly 64 lowercase hex characters (32-byte
  transaction id).
- `IX` is a non-negative decimal integer (output index).

Parsing rejects: uppercase hex, missing `#`, non-numeric index,
negative index, surplus characters after the index, hash shorter
than or longer than 64 chars, empty input.

## Operator log lines

For each `--exclude-utxo` ref that matches the candidate pool, the
wizard logs an attribution line to stderr in input order:

```text
<wizard>: excluded utxo <outref> (operator-supplied) [wallet]
<wizard>: excluded utxo <outref> (operator-supplied) [treasury]
<wizard>: excluded utxo <outref> (operator-supplied) [both]
<wizard>: excluded utxo <outref> (operator-supplied) [absent]
```

`[wallet]` / `[treasury]` / `[both]` name the pool(s) the ref hit
(swap-wizard is the only wizard that can hit `[both]`; the others are
single-pool). `[absent]` is the "inert exclusion" case — the operator
passed an outref that the chain query did not return, the wizard
makes no selection change, but logs that the flag was processed so
the operator sees it took effect.

## Contradictory inclusion/exclusion

Passing the same `TX_HASH#IX` to both `--exclude-utxo` and
`--extra-tx-in` on the same wizard invocation is a fast-fail error:

```text
<wizard>: contradiction: <outref>
```

The check runs BEFORE any chain query, pparams query, or artifact
parse, so a contradictory invocation never incurs a node round-trip.
Exit code is non-zero.

## Shortfall with excluded refs

If `--exclude-utxo` filters all candidates out of a pool, the wizard
errors with its standard `WalletNoPureAda` / `WalletShortfall` (or
treasury-equivalent) shape, and the error message names every
excluded outref so the operator knows whether to lift one:

```text
<wizard>: wallet shortfall available=0 required=2000000
excluded utxos:
<outref-1>
<outref-2>
```

## `--extra-tx-in` not on wallet

If `--extra-tx-in <R>` names an outref that the wizard's wallet
chain query did NOT return, the wizard errors with:

```text
<wizard>: extra input not found on wallet: <outref-1>, <outref-2>
```

Multiple missing refs are listed together. Exit code is non-zero.

## How parity is guaranteed across wizards

Every in-scope wizard consumes the same
`Amaru.Treasury.Wizard.InputControl.excludeUtxoP` and
[`extraTxInP`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Wizard/InputControl.hs)
optparse-applicative parsers, the same `validateInputControl`
contradiction check, and the same `filterPool` pool-filter. The
`--help` phrasing for both flags is therefore identical across the
seven in-scope wizards by construction.

## Relationship to in-flight build auto-detection (#183)

[#183](https://github.com/lambdasistemi/amaru-treasury-tx/issues/183)
is the principled fix for the same operator pain: the wizard would
walk the `transactions/<year>/<scope>/<slug>/` archive and
automatically exclude UTxOs already referenced by an unsubmitted
build on the same host. `--exclude-utxo` is the manual escape hatch
that survives independently of #183 — it covers the "I have a
specific operational reason this UTxO is off limits" cases that
auto-detection cannot reason about. When both ship, `--exclude-utxo`
is the operator's explicit override layer on top of #183's
auto-detection.

## Out of scope

- `--include-only-utxo` whitelist mode — possibly useful but a
  different shape; file separately if wanted.
- Auto-population of the exclusion list from chain-side mempool
  hints — hard to do reliably from N2C.
- Treasury-side `--extra-tx-in` — wallet-side forced inclusion only
  in this iteration. Treasury inputs are selected per-scope; forced
  inclusion semantics for the treasury pool needs its own design
  pass.
- Treasury-side filtering for `reorganize-wizard` — reorganize
  consumes ALL UTxOs at the per-scope treasury address (no
  selection), so `--exclude-utxo` cannot be applied there without
  changing reorganize semantics; the flag filters the wallet pool
  only.
