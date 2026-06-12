# amaru-treasury-tx

CLI for building unsigned Conway transactions against the Amaru
treasury contracts, creating detached vault-backed witnesses, and
assembling/submitting signed transactions on top of the
[`cardano-node-clients` `TxBuild` DSL][txbuild].

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

A hosted operator web app runs at
**<https://amaru-treasury.plutimus.com>** — View (dashboard), Audit
(history + RDF-resolved tx detail + SPARQL/SHACL lenses), Operate (build
unsigned txs in the browser, with a Graph tab previewing the resolved
spend→produce effect), and Books. It builds unsigned transactions only.

## Quick links

- [**Quickstart**](quickstart.md) — wizard-to-`tx-build` pipes, pre-signing report review, and vault-backed witness creation.
- [Inspect and config profiles](inspect.md) — read-only treasury snapshots, profile-based startup, and compatibility flags.
- [Treasury history RDF demo](history-rdf-demo.md) — CLI and HTTP examples for named SPARQL queries, filters, and SHACL validation.
- [Treasury history RDF case study](history-rdf-case-study.md) — how ATX metadata, Cardano Ledger RDF, SPARQL, and SHACL compose for transaction-history analysis.
- [Architecture overview](architecture.md) — modules and data flow.
- [Trust model](trust-model.md) — what the wizard verifies, what the operator must assert.
- [Swap recipe](swap.md) — building an existing swap intent with `tx-build`.
- [Disburse](disburse.md) — resolving owned-scope ADA or USDM disbursements with `disburse-wizard`, multi-scope contingency ADA disburses with `disburse-wizard --scope contingency --to <scope>:<ada>`, or building an existing disburse intent with `tx-build`.
- [Withdraw](withdraw.md) — resolving treasury rewards with `withdraw-wizard` or building an existing withdraw intent.
- [Reorganize](reorganize.md) — consolidating or splitting treasury UTxOs with `reorganize-wizard`, with automatic batching when the whole scope does not fit one transaction.
- [Report render](report-render.md) — turning a `tx-build` build-output envelope into reviewable Markdown with `report-render`.
- [Wizard input control](wizard-input-control.md) — `--exclude-utxo` / `--extra-tx-in` flags shared by every wizard that selects wallet or treasury UTxOs (#184).
- [API container indexer](api-container-indexer.md) — how the `amaru-treasury-tx-api` container serves reads from its embedded chain-sync indexer.
- [Local devnet smoke](local-devnet-smoke.md) — opt-in live `cardano-node-clients` devnet node check.
- [ChainContext](chain-context.md)
- [Freeze workflow](freeze-workflow.md) — pinning a `ChainContext` for offline parity tests.
- [Parity report](parity.md)
- [Release automation](release.md)
- [Spec / plan / tasks](https://github.com/lambdasistemi/amaru-treasury-tx/tree/main/specs)
- [Source](https://github.com/lambdasistemi/amaru-treasury-tx)

## Capabilities

| Command | Purpose |
| :------ | :------ |
| `swap-wizard` | Verify upstream `metadata.json` against the chain, resolve UTxOs + tip, emit a unified swap `intent.json` (typed step trace via `WizardEvent`). |
| `swap-cancel` | Verify an explicitly supplied pending SundaeSwap order and build unsigned cancellation CBOR that returns the order value to the selected treasury. |
| `withdraw-wizard` | Verify upstream `metadata.json` against the chain, resolve the treasury reward account + reward balance, emit a unified withdraw `intent.json`, or exit cleanly when rewards are zero. |
| `disburse-wizard` | Verify upstream `metadata.json` against the chain, resolve wallet and treasury UTxOs, emit a unified ADA or USDM disburse `intent.json`. USDM is the default unit. With `--scope contingency`, disburses ADA from the contingency treasury to one or more destination scopes via repeatable `--to <scope>:<ada>` (each scope receives its exact amount; fee from the wallet). |
| `tx-build` | Turn a unified `intent.json` into unsigned Conway CBOR; re-evaluates every redeemer against a live `ChainContext` (typed step trace via `BuildEvent`) and can write a deterministic pre-signing report with `--report PATH`. |
| `vault create` | Import one pasted or streamed Cardano payment signing key (`cardano-cli` `.skey` JSON or `addr_xsk`) into an encrypted age witness vault. |
| `witness` | Create one detached Conway vkey witness from an encrypted age vault identity. |
| `attach-witness` | Merge detached vkey witness CBOR hex into an unsigned Conway transaction. |
| `submit` | Submit signed Conway CBOR hex through a local node socket. |
| `swap-quote` | Prepare a quote-derived swap run: fetch or read an ADA/USDM quote, apply the slippage policy, and write `intent.json` + `params.json` + logs into `--out-dir`. |
| `reorganize-wizard` | Produce a reorganize `intent.json` from registry and treasury UTxO state. |
| `treasury-inspect` | Read-only report: treasury balances + pending SundaeSwap orders per scope. |
| `history` / `tx-detail` | Read-only treasury tx history for a scope / one decoded transaction, from the local chain-sync indexer (`--indexer-db` or `AMARU_TREASURY_API_INDEXER_DB`). |
| `report-render` | Render a `tx-build` build-output envelope as reviewable Markdown. |
| `envelope-tx` / `envelope-witness` / `envelope-signed-tx` / `de-envelope` | Wrap raw CBOR hex as `cardano-cli` Conway envelopes and back. |
| `serve` | Run the HTTP API service (same server as the `amaru-treasury-tx-api` executable). |
| `registry-init-wizard` / `stake-reward-init-wizard` / `governance-withdrawal-init-wizard` | Produce bootstrap `intent.json` files for the DevNet registry, stake-reward, and governance-withdrawal flows (devnet only). |

`tx-build` reads the action discriminator and the network from
the intent itself (single source of truth) and dispatches to the
matching builder.

| Intent action | Release status |
| :------------ | :------------- |
| `swap` | Built from wizard output or an existing intent. Pinned by a frozen-context byte-identity golden — see the [parity report](parity.md). |
| `disburse` | ADA and USDM disburse intents build through `tx-build`. ADA is pinned by a frozen-context golden derived from the upstream bash/cardano-cli scenario; USDM has structural builder and resolver regression coverage. |
| `withdraw` | Built from wizard output or an existing intent. Pinned by a synthetic frozen-context golden until issue #17 records a live preprod oracle. |
| `reorganize` | Built from wizard output or an existing intent, with an automatic batcher when the scope holds more treasury UTxOs than fit one transaction — see [Reorganize](reorganize.md). Pinned by a frozen-context golden. |

## Out of scope

- Implicit signing during `tx-build`.
- Vault custody policy, recipient rotation, and key ceremony design.
- Registry / scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
