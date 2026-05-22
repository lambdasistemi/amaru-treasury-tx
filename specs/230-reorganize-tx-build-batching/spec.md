# 230 — reorganize tx-build auto-batches the largest fitting subset

## Context

Issue: [#230](https://github.com/lambdasistemi/amaru-treasury-tx/issues/230)
Parent epic: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
Predecessors:

- [#212](https://github.com/lambdasistemi/amaru-treasury-tx/issues/212) — phase-2 scopes-NFT (PR #214, `5bb75425`)
- [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217) — wizard UTxO selection (PR #219, `cc6ba631`)
- [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218) — mainnet path (PR #223, `d426d059`)

## Root cause of the current block

After #218, `reorganize-wizard --network mainnet` emits intents that
enumerate **every** treasury fund UTxO. `tx-build --intent` then tries
to spend all of them in a single tx; on real treasuries each
spending redeemer evaluation inspects the full script context, so
total exec units grow super-linearly in input count (~ `O(N²)`).

Measured against mainnet (`/code/cardano-mainnet/ipc/node.socket`,
`0.2.13.0`):

```
network_compliance: 55 UTxOs at the treasury address.
tx-build → ExUnitsTooBigUTxO
  supplied: mem 371,468,288 / steps 130,657,229,151
  expected: mem  16,500,000 / steps  10,000,000,000
```

22× over memory, 13× over steps. The tx is unsubmittable.

## P1 user story — operator command

Operator runs the unchanged operator command:

```bash
amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  reorganize-wizard \
    --metadata /code/amaru-treasury/journal/2026/metadata.json \
    --scope network_compliance \
    --wallet-addr <bech32> \
    --funding-seed-txin <txin> \
    --out /tmp/network_compliance.intent.json

amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  tx-build \
    --intent /tmp/network_compliance.intent.json \
    --out /tmp/network_compliance.cbor.hex
```

`tx-build` produces a tx body that **submits** — consolidating the
largest input subset that fits the per-tx exec-unit ceiling — and
prints the unselected outrefs so the operator can chain another
wizard run on the residue. Repeating the operator command on the
residue (after the first batch lands on-chain) consolidates further,
until ≤ 1 UTxO remains at the scope (no more reorganize possible).

## Owned-files surface

This PR touches:

- `lib/Amaru/Treasury/Build/Reorganize.hs` — add the sample-fit-solve
  loop around the existing `build → align → validate` path. The
  truncated set is rebuilt with a smaller `preservedValue` and
  smaller `treasuryInputs` list.
- `lib/Amaru/Treasury/Tx/Reorganize.hs` — `reorganizeProgram` already
  takes the input set as a parameter; no change to its shape.
- `lib/Amaru/Treasury/Build/Result.hs` (or a new `Reorganize/Batch.hs`)
  — extend `BuildResult` (or sibling) with a `brResidualTreasuryInputs ::
  [TxIn]` field so the runner can surface what was dropped.
- `lib/Amaru/Treasury/Cli/TxBuild.hs` — print the residue on stdout /
  log: `reorganize: selected N of M UTxOs; residue: [TxId#Ix, …]`.
- `test/unit/Amaru/Treasury/Build/Reorganize/BatchSpec.hs` (new) — pure
  unit tests of the math: given a synthetic `(measured cost, limit)`
  pair, the scaler returns the expected `N*`.

## Math (this is the "challenge")

Phase-2 cost per reorganize tx, measured empirically:

```
cost(N) ≈ a + b·N²
```

where `a` is the fixed withdraw-redeemer + scopes-lookup overhead and
`b·N²` is the dominant per-spending-redeemer cost (each redeemer's
evaluation runs work proportional to the size of the script context,
which itself is proportional to `N`).

We do **not** need to recover `a` and `b` independently. Given:

- `cost(N_full) = total` measured by `ccEvaluateTx`
- `limit = α · maxTxExecutionUnits` (per dimension, with `α ≈ 0.85`)

…and assuming `a` is small relative to the per-input contribution
(or, equivalently, assuming `cost(N) ≈ k · N²`), the safe `N*` is:

```
N* = floor(N_full · sqrt(limit / total))
```

Applied to both `memory` and `steps`, the binding `N*` is the
smaller. Tx size is checked separately as a linear cap.

If `a` is non-negligible, this estimator is **conservative** — it
picks a smaller `N*` than strictly necessary, which is safe. A second
iteration (rebuild at `N*`, re-measure, re-scale) refines if needed.
In practice 1–2 iterations converge.

This is **closed-form** (one sqrt), not iterative bisection. Each
iteration costs one `build + evaluator` round-trip.

## Selection ordering

When truncating from `N_full` to `N*`, prefer the **largest-value**
UTxOs (by lovelace + asset-value-at-natural-unit) so the consolidation
yield per batch is maximized. The residue (smallest-value UTxOs) is
the easiest set to feed into a second batch.

Sort comparator: `(lovelace desc, then USDM-asset-quantity desc)`. The
asset name comparator is operator-tunable in a follow-up; this PR
hard-codes the lovelace-dominated comparator and documents the
limitation.

## Acceptance criteria

1. `nix develop -c just ci` green.
2. Pure unit RED-then-GREEN: given a synthetic `(measured cost,
   limit, N_full)` triple, `scaleNStar` returns the expected `N*`.
   Several boundary cases: `N_full = 2` (returns 2), `total < limit`
   (returns N_full), `total ≫ limit` (returns small N*), `α` cap
   respected.
3. Build-path test: on a frozen `ChainContext` with N UTxOs whose
   per-input phase-2 cost is fabricated to exceed the limit, the
   reorganize action produces a tx with a strict subset of inputs
   and logs the residue.
4. **Live mainnet evidence on `network_compliance`** (55 UTxOs at
   probe time): `tx-build --intent` produces a tx body that passes
   `validateFinalPhase1` AND phase-2 (`re-evaluated K redeemers, 0
   failed`), and `tx-build` prints the residue outrefs. The cbor.hex
   + tx-inspect summary are archived as PR evidence.
5. **Idempotence demo**: after the first batch lands (we don't
   submit in this PR — just demonstrate the math), running
   `reorganize-wizard` against the simulated post-batch chain state
   produces a second intent for the residue that itself batches
   cleanly.
6. `gate.sh` passes before push.
7. **No merge without explicit operator sign-off** — the artifact
   evidence is the PR-body content; the operator inspects it and
   approves before merge.

## What this PR does NOT deliver

- Submission of the produced tx body (build-only CLI surface).
- Auto-chunking of the wizard's emitted intent (this PR keeps the
  wizard "emit everything" behavior; the picker is in `tx-build`).
- An `--max-inputs N` operator override flag — the math picks
  automatically. If the operator wants a smaller batch than the
  math chooses, they can re-run the wizard against a manually
  filtered scope, which is awkward; an `--max-inputs N` override
  is a follow-up if needed.
- Cross-scope or multi-tx batching pipelines.
- The asset-preference ordering knob (lovelace dominant assumed).

## Open design points (for the implementation pass to decide)

- **Where to put the math.** Inside `runReorganizeAction` (close to
  `ccEvaluateTx`) is simplest. A new helper `Build.Reorganize.Batch`
  module makes the math testable in isolation; preferred.
- **Iteration cap.** Bound at 3 rebuilds (one full + two refinements);
  log loudly if still over-budget and bail with a typed error so the
  operator can rerun with hand-picked inputs.
- **Residue surfacing.** Stdout log line + a `--residue-out PATH`
  flag that writes a JSON list to disk for downstream automation;
  the JSON form lands in this PR, the flag wiring is part of the
  same slice.
