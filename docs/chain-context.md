# ChainContext

The chain‑side inputs to a deterministic transaction build, captured
as a single value.

## Why

Every Cardano tx build needs five things from the outside world:

1. **Protocol parameters** at a moment in time (fee coefficients,
   cost models, collateral percentage).
2. **Resolved UTxOs** for every input the tx refers to (wallet,
   treasury, reference scripts).
3. The **network id** and **tip slot** for that same ledger view.
4. A **script evaluator** that runs Plutus redeemers against a
   draft tx so the builder can patch in the right `ExUnits`.
5. A **phase-1 validation context** for the final unsigned tx.

Bundling these into a record makes the dependency on "reality"
explicit, replaceable, and testable.

```haskell
data ChainContext = ChainContext
    { ccNetwork    :: Network
    , ccTipSlot    :: SlotNo
    , ccPParams    :: PParams ConwayEra
    , ccUtxos      :: Map TxIn (TxOut ConwayEra)
    , ccEvaluateTx :: ConwayTx -> IO (EvaluateTxResult ConwayEra)
    }
```

`runFromIntent` and the action-specific builders accept a
`ChainContext` and nothing else from the live chain. Whichever way
the context was populated — live node, snapshot, mocked evaluator —
the build is the same code path.

## Live mode

The release-facing CLI paths use `withLiveContext`. It acquires one
local-node N2C query handle, samples protocol parameters, required
UTxOs, tip slot, and network, then keeps the build and evaluator calls
inside the acquired callback. That matters because the builder can call
the evaluator more than once while converging fees and `ExUnits`.

```haskell
import Amaru.Treasury.ChainContext (withLiveContext)

withLiveContext network provider (Set.fromList allRequiredTxIns) $ \ctx ->
    runFromIntent ctx intent
```

`liveContext` still exists for one-shot callers, but production builds
prefer `withLiveContext` so protocol parameters, UTxOs, tip slot, and
script evaluation all come from one sampled view.

After building and fee alignment, the action runners call
`Cardano.Tx.Validate.validatePhase1` through
`Build.Common.validateFinalPhase1`. Missing vkey witnesses are expected
for an unsigned transaction and are filtered out; remaining ledger
failures abort the build before CBOR is written.

## Frozen mode

Same record, populated from fixtures:

- `pparams` — a JSON snapshot recorded once via `cardano-cli query
  protocol-parameters`.
- UTxOs — a small JSON / CBOR pack carrying value and reference
  script for each `TxIn` the build will reference.
- network and tip slot — fixed values used by the final phase-1
  preflight.
- evaluator — usually a `pure (Right knownExUnits)` map keyed by
  redeemer purpose, captured during a previous live run.

```haskell
import Amaru.Treasury.ChainContext (frozenContext)

let ctx = frozenContext frozenPParams frozenUtxos pureEvaluator
```

Use `frozenContextAt` when the test needs to pin a specific network or
slot instead of the default mainnet slot `0`.

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
        └───────────────────────┘     re-evaluate, phase-1 validate
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
