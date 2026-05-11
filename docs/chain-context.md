# ChainContext

The chain‑side inputs to a deterministic transaction build, captured
as a single value.

## Why

Every Cardano tx build needs three things from the outside world:

1. **Protocol parameters** at a moment in time (fee coefficients,
   cost models, collateral percentage).
2. **Resolved UTxOs** for every input the tx refers to (wallet,
   treasury, reference scripts).
3. A **script evaluator** that runs Plutus redeemers against a
   draft tx so the builder can patch in the right `ExUnits`.

Bundling these into a record makes the dependency on "reality"
explicit, replaceable, and testable.

```haskell
data ChainContext = ChainContext
    { ccPParams    :: PParams ConwayEra
    , ccUtxos      :: Map TxIn (TxOut ConwayEra)
    , ccEvaluateTx :: ConwayTx -> IO (EvaluateTxResult ConwayEra)
    }
```

`runFromIntent` and the action-specific builders accept a
`ChainContext` and nothing else from the live chain. Whichever way
the context was populated — live node, snapshot, mocked evaluator —
the build is the same code path.

## Live mode

The CLI and the parity probe use this path. It queries a `Provider`
(currently `Amaru.Treasury.Backend.N2C` over the local-node N2C
socket) for everything needed by a known set of `TxIn`s and surfaces
"missing UTxO" errors before the build starts.

```haskell
import Amaru.Treasury.ChainContext (liveContext)

ctx <- liveContext provider (Set.fromList allRequiredTxIns)
```

## Frozen mode

Same record, populated from fixtures:

- `pparams` — a JSON snapshot recorded once via `cardano-cli query
  protocol-parameters`.
- UTxOs — a small JSON / CBOR pack carrying value and reference
  script for each `TxIn` the build will reference.
- evaluator — usually a `pure (Right knownExUnits)` map keyed by
  redeemer purpose, captured during a previous live run.

```haskell
import Amaru.Treasury.ChainContext (frozenContext)

let ctx = frozenContext frozenPParams frozenUtxos pureEvaluator
```

A frozen `ChainContext` makes the build immune to:

- The original wallet / treasury inputs being spent.
- Pparams drifting at an epoch boundary.
- Hard forks or governance-driven cost-model changes.
- Network outages.

The same `runFromIntent` path produces byte-identical CBOR
regardless.

## Where it sits in the stack

```
┌─────────────────────────────────────────────┐
│      amaru-treasury-tx tx-build             │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
        ┌───────────────────────┐
        │  ChainContext         │  ← reality (live | frozen)
        └───────────────────────┘
                   │
                   ▼
        ┌───────────────────────┐
        │  Build        │  ← dispatcher: translate,
        │     runFromIntent     │     build, fee-align,
        └───────────────────────┘     re-evaluate
                   │
                   ▼
        ┌───────────────────────┐
        │  Tx.Swap              │  ← pure TxBuild q e () program
        │     swapProgram       │     (DSL, no IO)
        └───────────────────────┘
```

The split is enforced by types: pure transaction programs cannot do
IO, `Build` cannot read pparams or query UTxOs except
through the context, and the CLI or golden harness chooses whether
that context is live or frozen.
