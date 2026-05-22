# Building a reorganize transaction

`reorganize-wizard` enumerates the treasury UTxOs at a per-scope
treasury address and emits a unified `intent.json`. `tx-build`
consumes that intent and builds the unsigned Conway CBOR. There is
no release-facing `reorganize` builder command.

The reorganize action merges multiple treasury UTxOs at the same
per-scope treasury script address into one continuing UTxO. The
treasury's lovelace and native-asset value are preserved end-to-end
(Conway's `ValueNotConservedUTxO` rule enforces this at phase-1); the
only cost is the per-tx network fee paid out of the operator's
wallet.

See [Wizard input control](wizard-input-control.md) for the
`--exclude-utxo` / `--extra-tx-in` flags shared with every other
wizard (these affect the wallet pool only — treasury subset
selection happens in `tx-build`'s batcher, below).

## CLI usage

Set the node socket once:

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
```

Fetch the 2026 treasury metadata:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
  -o metadata.json
```

The wizard treats this file as an untrusted hint. It verifies the
consumed registry fields against the on-chain anchors before emitting
an intent.

### Wizard

```bash
amaru-treasury-tx --network mainnet reorganize-wizard \
  --metadata metadata.json \
  --scope <scope> \
  --wallet-addr <operator-wallet-bech32> \
  --out reorganize.intent.json
```

Required arguments:

- `--scope NAME` — `core_development`, `ops_and_use_cases`,
  `network_compliance`, `middleware`, or `contingency`.
- `--wallet-addr BECH32` — operator wallet, source of fee + collateral.
- `--out PATH` — where to write the `intent.json`.

Optional arguments:

- `--funding-seed-txin TXID#IX` — operator-named wallet UTxO to use
  for fuel + collateral. When omitted, the wizard auto-picks the
  largest pure-ADA UTxO at `--wallet-addr` (same shape as
  `disburse-wizard` / `withdraw-wizard` / `swap-wizard`). Pass an
  explicit outref when you want to pin a specific UTxO — typically
  to avoid colliding with a parallel in-flight build.

- `--validity-hours HOURS` — explicit upper validity bound. Defaults
  to the chain's current safe horizon.
- `--description / --justification / --label / …` — overrides for
  the on-chain CIP-1694 rationale metadata.

The wizard emits an `intent.json` whose `reorganize.treasuryUtxos`
field lists **every** UTxO at the scope's treasury script address
(excluding script-deploy reference UTxOs, which are filtered at the
query boundary). On treasuries with many small UTxOs the candidate
list will exceed any single tx's per-tx exec-unit ceiling; the
downstream `tx-build` step handles that automatically via batching.

### Build

```bash
amaru-treasury-tx --network mainnet tx-build \
  --intent reorganize.intent.json \
  --out reorganize.cbor.hex
```

`tx-build` reads the intent, queries the live chain context, and
constructs the Conway tx body. When the wizard-emitted treasury
list exceeds the per-tx `maxTxExUnits` ceiling, the batcher kicks
in (see next section). The produced CBOR is unsigned; sign and
submit with the existing vault tooling described in the project's
manual + signing skills.

## Auto-batching: `tx-build` picks the largest fitting subset

The reorganize tx spends every selected treasury UTxO with a Plutus
redeemer; each redeemer evaluation inspects the full script context,
so per-tx exec-unit cost grows roughly as `O(N²)` in input count. On
real treasuries (e.g. mainnet `network_compliance` with 54+ small
USDM UTxOs) a "merge everything" tx blows the per-tx ceiling by an
order of magnitude and cannot submit.

`tx-build` solves this with a **projected linear descent**:

1. Build the tx with the full wizard-emitted treasury list. Measure
   the actual Plutus exec units + serialised tx size.
2. If the measurement fits the ledger's `maxTxExUnits` and
   `maxTxSize`, accept it as the batch and emit the CBOR.
3. Otherwise take a **closed-form sqrt projection** for the largest
   `N*` whose projected cost fits:
   ```
   N* = floor(currentN · sqrt(limit / measured))
   ```
   applied to each cap independently; the binding `N*` is the
   smaller.
4. Rebuild with the largest-value `N*` UTxOs. Measure again.
5. If the rebuild still doesn't fit, step **down by 1** and repeat
   until the measurement fits or the iteration budget is exhausted
   (cap = 5 rebuilds).

The projection is only the initial guess; every candidate `N` is
confirmed by a real Plutus evaluation against the live ledger
limits, so no safety alpha is needed — the descent walks right up
to the empirical cliff. On a 54-UTxO `network_compliance` probe the
descent converges in 3 builds (`54 → 11 → 10`) and lands on the
true cliff (`N=10` fits, `N=11` overflows memory by ~5%).

After the batcher picks, `tx-build` prints:

```
tx-build: reorganize: batched 10 of 54 UTxOs (44 residue: …, …, …)
```

The 44 residue outrefs are exactly the UTxOs the operator chains
into a subsequent reorganize after this batch settles on-chain.

Selection ordering: **largest-value first** by lovelace
(`Cardano.Ledger.Coin`). Native-asset value isn't a tiebreaker in
this iteration; if you need to bias selection toward USDM-heavy
UTxOs first, hand-edit `intent.json` before `tx-build` or file a
follow-up for an explicit ordering knob.

## Iterating: chaining batches

Compressing a large treasury takes several batches. After the first
batch's tx settles on-chain (signed + submitted via the vault
tooling), the residue UTxOs are still at the same address, and the
wizard's next chain query enumerates the residue + the new merged
output (which is now the largest-value UTxO at that address). Run
the same operator command again with a fresh `--funding-seed-txin`,
and the batcher picks the next 10-ish UTxOs from the residue
naturally.

Rough cardinality: with the projected-linear-descent picking ~10
inputs per batch and producing 1 merged UTxO (net `-9` per batch),
a 54-UTxO treasury collapses to ≤ 1 UTxO in roughly `⌈54 / 9⌉ = 6`
batches.

Per-batch costs are dominated by Plutus script execution — a
single 10-input batch costs ~1.5 ADA in network fees out of the
operator wallet. The treasury itself is value-conserving (no
treasury lovelace leaves the address); what the batches *do* free
is the per-UTxO min-UTxO floor that was previously locked across
each separate UTxO. A 54-UTxO treasury holding ~50 small UTxOs at
~2.5 ADA min-UTxO each has ~125 ADA locked in min-UTxO floor;
collapsing those into 1 UTxO frees roughly `49 × 2.5 = ~123 ADA`
of formerly-locked lovelace for subsequent treasury operations.

## Verification

`tx-build` runs the full Plutus evaluator against the produced tx
body before writing CBOR. The trace line `tx-build: VALIDATION OK`
confirms phase-1 + phase-2 acceptance against the sampled chain
context. To inspect the resulting tx body offline:

```bash
# Wrap the raw hex in a TextEnvelope cardano-cli can read:
cat > tx.envelope.json <<EOF
{
  "type": "Unwitnessed Tx ConwayEra",
  "description": "Ledger Cddl Format",
  "cborHex": "$(cat reorganize.cbor.hex)"
}
EOF

cardano-cli debug transaction view --tx-file tx.envelope.json
```

Or use the project's `tx-inspect` from
[`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
(note: empty multi-asset maps are currently elided from
`tx-inspect`'s output — see
[`cardano-tx-tools#84`](https://github.com/lambdasistemi/cardano-tx-tools/issues/84)).

## Limits and follow-ups

- Treasury-side `--exclude-utxo` for surgical exclusion of a
  specific treasury outref is not in the wizard yet. Workarounds:
  hand-edit `intent.json` before `tx-build`, or let the residue
  carry the unwanted UTxO into a later batch.
- Native-asset-biased selection ordering (`USDM desc` before
  `lovelace desc`) is not exposed. The current ordering is
  lovelace-only.
- Iteration cap is 5 rebuilds; pathological cost shapes that don't
  fit even at `N=2` raise a typed error and ask the operator to
  re-run against a smaller scope or with a hand-edited intent.
