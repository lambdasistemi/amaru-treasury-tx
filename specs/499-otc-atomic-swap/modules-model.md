# Modules model — atomic OTC swap (issue #499)

Dependency direction is downward only. No new module imports a wizard
or CLI module.

```text
Cli                        subcommand registration
  └── Cli.OtcSwapWizard    option parsing, IO runner, intent.json write
        └── Tx.OtcSwapWizard   selection + resolution + intent assembly
              ├── IntentJSON        wire contract, translation
              │     └── IntentJSON.Schema
              └── Tx.OtcSwap        typed payload + TxBuild program
                    └── Redeemer    two-legged Disburse encoder
Build                      dispatcher
  └── Build.OtcSwap        ChainContext-driven build runner
        └── Tx.OtcSwap
```

## New modules

**`Amaru.Treasury.Tx.OtcSwap`** — owns the typed OTC payload and the
`TxBuild` program. Peer of `Amaru.Treasury.Tx.Disburse`; does not
import it. Holds no IO and no chain access.

**`Amaru.Treasury.Build.OtcSwap`** — resolves the typed intent against
a `ChainContext`, runs the program, aligns the fee, validates phase-1,
re-evaluates scripts, assembles the build result. Peer of
`Amaru.Treasury.Build.Disburse`.

**`Amaru.Treasury.Tx.OtcSwapWizard`** — selection and resolution:
treasury UTxOs funding the ADA leg, the counterparty UTxO holding the
incoming asset, the operator fuel/collateral UTxO, the validity bound,
and rationale assembly. Owns the pure decisions; IO is confined to the
resolver entry point, matching `Tx.DisburseWizard`.

**`Amaru.Treasury.Cli.OtcSwapWizard`** — the `otc-swap-wizard` parser,
its options record, and the runner that writes `intent.json`.

## Changed modules

**`Amaru.Treasury.Redeemer`** — gains a two-legged encoder taking a
signed incoming quantity. The existing `disburseAdaRedeemer` and
`disburseUsdmRedeemer` keep their signatures and their pinned vectors;
the new encoder is additive.

**`Amaru.Treasury.IntentJSON`** — gains an `OtcSwap` arm on `Action`,
its `SAction` singleton, the `Payload`/`Translated` type-family
instances, the payload record with its codec, and the translation to
the typed payload. `allowedSchemas` is unchanged: the new action is a
sibling under the existing schema version, not a new version.

**`Amaru.Treasury.IntentJSON.Schema`** — gains an `otcSwap` block.
The existing `disburseSchema` is untouched, including its
`positiveIntegerSchema` amount rule.

**`Amaru.Treasury.Build`** — gains the dispatcher arm routing
`SOtcSwap` to `Build.OtcSwap`.

**`Amaru.Treasury.Cli`** — registers the subcommand and its `Cmd` arm.

**Report rendering** — the report gains the two legs, the stated price,
the counterparty, and the signature roster split into multisig
participants and ledger-level UTxO owners.

## Abstraction promotion

None is justified yet. `Tx.OtcSwap` and `Tx.Disburse` will visibly
share the reference-input/withdraw-zero/required-signer preamble.
That duplication is deliberate for this ticket: the disburse path is
live on mainnet, and a shared preamble extracted now would modify it
under a feature that has never run. Promote only after the swap path
has settled on chain, as its own refactor with its own goldens.

## Explicitly unchanged

`Amaru.Treasury.Constants` keeps its USDM singleton, used solely by the
existing disburse path. The OTC path never reads it: asset identity
arrives in the intent (FR-007).
