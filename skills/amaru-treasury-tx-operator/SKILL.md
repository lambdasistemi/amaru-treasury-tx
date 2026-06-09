---
name: amaru-treasury-tx-operator
description: End-to-end operator workflow for driving the `amaru-treasury-tx` CLI against the Amaru treasury contracts on any host. Build → witness → assemble → inspect → validate → submit → archive into the in-repo `transactions/` log. Load this whenever the user invokes `amaru-treasury-tx`, `attach-witness`, `treasury-inspect`, any of the `*-wizard` subcommands (`disburse-wizard` (use `--scope contingency --to <scope>:<ada>` for a contingency disburse), `withdraw-wizard`, `swap-wizard`, `swap-cancel`), mentions disbursing / withdrawing / swapping from a treasury, references age-encrypted witness vaults, or talks about archiving an Amaru treasury tx. The first time this skill runs on a new machine it conducts a one-time first-run interview, writes the operator's answers to `~/.config/amaru-treasury-tx/operator.json`, and reuses them thereafter — so subsequent runs propose complete commands instead of asking for paths and identities again.
---

# `amaru-treasury-tx` operator workflow

Portable operator reference for the Amaru treasury transaction
pipeline. Designed to run anywhere the `amaru-treasury-tx` binary,
a local cardano-node, and the operator's vault are available —
mainnet, preview, or preprod.

## STOP — first-run interview

**Before doing anything else, check whether
`~/.config/amaru-treasury-tx/operator.json` exists.**

```bash
test -f "${XDG_CONFIG_HOME:-$HOME/.config}/amaru-treasury-tx/operator.json"
```

If it doesn't, walk the operator through the questions in
[references/first-run-interview.md](references/first-run-interview.md),
write the answers to that file (schema in
[references/operator-config-schema.md](references/operator-config-schema.md)),
and confirm them back before proceeding. The whole pipeline below
substitutes `<config.field>` placeholders with values from this
file — never hardcode paths or identities into proposed commands.

If the file exists, **read it once** at session start and stop
re-asking for anything it answers (wallet address, scope-owner
roster, vault paths, node socket, metadata path). Re-asking is the
signature of a session that skipped the first-run check.

## Golden rule

**Use the project's own subcommands. Do not hand-roll CBOR.** The CLI
ships first-class primitives for every step (envelope/de-envelope,
witness production, witness merge, validation, submission). Hand-rolled
CBOR risks subtle wire-format bugs — CBORTag 258 for sets, vkey-witness
inner shape vs Shelley `[0, [vkey, sig]]` wrap, body-bytes-preserve
invariant.

## Install & invoke

The release binary is statically linked. Recommended:

1. **PATH binary** at `~/bin/amaru-treasury-tx` — drop the AppImage
   asset there, `chmod +x`, just call it by name.
2. **Distro package** (DEB / RPM) — when installing system-wide.
3. **`nix run` / `cabal run` from a checkout** — last resort.

Update idiom:

```bash
LATEST=$(gh release view --repo lambdasistemi/amaru-treasury-tx \
              --json tagName --jq .tagName)
curl -fsSL -o ~/bin/amaru-treasury-tx \
  "https://github.com/lambdasistemi/amaru-treasury-tx/releases/download/$LATEST/amaru-treasury-tx.AppImage"
chmod +x ~/bin/amaru-treasury-tx
amaru-treasury-tx --version
```

Confirm `amaru-treasury-tx --version` matches what was just downloaded
and log the version into any artefact you produce — operators
correlate by it. The project ships fast.

## Per-session environment

Export the N2C socket from the operator config before any command
that talks to the node:

```bash
export CARDANO_NODE_SOCKET_PATH=<config.nodeSocket>
```

`--network <config.network>` is the global flag.

## Canonical pipeline

See [references/pipeline.md](references/pipeline.md) for the full
build → witness → assemble → inspect → submit → archive sequence with
verbatim commands and the `<config.field>` substitution rules.

```text
intent.json --tx-build-->  unsigned-tx.hex
                                 |
                                 v
            collect N detached witnesses (one per required signer)
                                 |
                                 v
unsigned-tx.hex + witnesses --attach-witness--> signed-tx.hex
                                 |
                                 v
                  tx-inspect / tx-validate / tx-diff
                                 |
                                 v
                  submit  (only after explicit operator go)
                                 |
                                 v
   archive into transactions/<year>/<scope>/<txid>/
   (verifiable bundle: inputs/, signed-tx, submit.log, submitted.json)
```

The archive step at the bottom is **mandatory**, not optional. Every
submitted tx must be promoted from the pre-submission slug entry to a
txid-named directory under the in-repo `transactions/` log. See
[references/transactions-log.md](references/transactions-log.md) for
the per-entry contract, the build-time entry, and the post-submission
refresh ceremony.

## Pre-flight discovery — don't re-ask what prior runs know

Before any wizard, mine recent history. Wallet address, scope id,
signer list, and rationale conventions are recurring values that
live in prior `intent.json` files and in `treasury-inspect` output.
Re-prompting the operator each time is a workflow gap.

```bash
# 1. Authoritative per-scope state (balances, UTxOs, pending orders):
amaru-treasury-tx --network <config.network> treasury-inspect \
  --metadata <config.metadataPath>

# 2. Most recent intent for any operation:
ls -t <config.scratchDirRoot>/*/intent.json 2>/dev/null | head -10

# 3. Reusable fields from a prior intent:
jq '{wallet: .wallet.address, scope: .scope.id, signers, rationale,
     swap: (.swap // null)}' <path>
```

What you genuinely still ask the operator (these are the real
decisions):

- size: `--usdm <N>` / `--all-ada`, plus `--split` or `--chunk-usdm`
- price: `--min-rate` (or `--ada-usdm` + `--slippage-bps`, or
  `swap-quote --price-source coingecko-ada-usdm`)
- `rationale.description` — 1-line "what" (size + rate + counterparty)
- `rationale.justification` — 1-line "why" (vendor, mandate, deadline)
- any non-default `--extra-signer …` beyond the roster in the config
- final go/no-go before `submit`

If a proposed command contains placeholders like
`<BECH32_FUEL_ADDR>` or `<rationale: ...>`, stop and re-derive them
from the config or discovery commands above. Bare placeholders mean
the first-run check was skipped.

## Subcommand cheat sheet

Run `amaru-treasury-tx <verb> --help` for canonical flag lists. The
verbs and their roles:

- **Wizards** (produce a unified `intent.json`):
  `disburse-wizard` (use `--scope contingency --to <scope>:<ada>` for a contingency disburse), `withdraw-wizard`,
  `swap-wizard`, `swap-cancel`. All take `--wallet-addr`,
  `--metadata`, scope/amount/rationale flags, optional
  `--validity-hours`, and write `intent.json` plus a `--log`.
- `tx-build --intent intent.json --out unsigned-tx.hex
  --report report.json --log build.log` — pure builder; emits raw
  CBOR hex.
- `envelope-tx` / `envelope-witness` / `envelope-signed-tx` — wrap
  raw hex into a Conway TextEnvelope (`Tx ConwayEra` /
  `TxWitness ConwayEra`).
- `de-envelope` — inverse: TextEnvelope → raw CBOR hex on stdout.
- `witness --tx <unsigned> --vault <age> --identity <label-or-hash>
  --expected-key-hash <hash> --out <file>` — produce one detached
  `[vkey, sig]` witness from an age-encrypted vault.
- `vault create …` — make a new age-encrypted vault from a signing
  key.
- `attach-witness --tx unsigned-tx.hex --witness HEX --witness HEX …
  --out signed-tx.hex` — merge any number of detached vkey witnesses
  into the unsigned tx. Accepts both raw `[vkey, sig]` and the
  `[0, [vkey, sig]]` Shelley envelope form.
- `treasury-inspect` — read-only report of treasury balances + pending
  SundaeSwap orders per scope.
- `submit --tx signed-tx.{hex|tx}` — broadcast through the N2C
  socket. Only after explicit operator approval; never submit on your
  own.

## Multi-owner signature requirements

The on-chain permissions validator requires more than just the
scope owner for most operations. The roster lives in the config
(see [references/operator-config-schema.md](references/operator-config-schema.md))
and is enforced chain-side, not by the wizard:

- **`reorganize`** — scope owner only.
- **`swap` / `disburse` / `withdraw`** — scope owner **plus at
  least one other** scope owner (`approved_by_owner_and_someone_else`
  in the permissions validator).
- **`contingency-disburse`** — **all four** scope owners must
  co-sign (full owner set).

⚠ The `swap-wizard` default `signers` list is the scope owner
*only* and will assemble cleanly but be rejected phase-2 at
submission. Always pass `--extra-signer <other-scope>` for swap /
disburse / withdraw flows. The operator config lists the full
roster keyed by scope label; pick any other owner from there.

## Reference-set disburses (Principle VIII v2 / v3)

Disbursements carry an on-chain `rationale.references` array binding
the tx to its off-chain audit chain (engagement contracts,
address-of-record proofs, invoices, cycle reviews). Drive every
disburse from a per-cycle manifest + per-disbursement build script —
never assemble the `--reference-uri / --reference-type /
--reference-label` trio by hand at the prompt.

See [references/reference-disburses.md](references/reference-disburses.md)
for the manifest schema, the CC build script as the canonical template,
the NDA carve-out (P-VIII v3 A), the **NON-NEGOTIABLE
amount-vs-invoice cross-check before signing**, the rebuild-via-wizard
rule when an in-flight disburse needs a correction (never
surgical-edit `intent.json`), and where to find the txId after
`tx-build`.

## Companion tools: `cardano-tx-tools`

If a local checkout of [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
exists at `<config.cardanoTxToolsPath>`, the operator skill defers
to its `tx-inspect`, `tx-validate`, and `tx-diff` apps for
human-readable inspection and pre-flight validation. If not, all
operations still work — these are belt-and-braces, not required.

See [references/pipeline.md](references/pipeline.md) for the
invocations.

## Age-encrypted vaults

Owners hold their signing keys inside age-encrypted *witness
vaults*. The `witness` subcommand decrypts in memory, signs the tx
body hash, and emits raw `[vkey, sig]` CBOR hex:

```bash
amaru-treasury-tx --network <config.network> witness \
    --tx <path-to-unsigned-tx.tx> \
    --vault <config.vaults.<owner-label>.path> \
    --identity <config.vaults.<owner-label>.identity> \
    --expected-key-hash <config.vaults.<owner-label>.keyHash> \
    --out <answers-dir>/A-NNN-witness-<owner-label>.md
```

- `--identity` accepts a label or a 28-byte hex hash. Passing the
  hash plus `--expected-key-hash` belt-and-braces against picking
  the wrong identity from a multi-identity vault.
- `--vault-passphrase-fd FD` scripts the passphrase; without it the
  tool prompts on the tty.
- Output is **raw** `[vkey (32), sig (64)]` CBOR hex — exactly
  what `attach-witness --witness HEX` expects.

## Standard runtime / log dir layout

```text
<config.scratchDirRoot>/<flow-name>/
├── wizard.log           # *-wizard step trace
├── intent.json          # unified intent (wizard --out)
├── build.log            # tx-build step trace
├── report.json          # deterministic build report
├── unsigned-tx.hex      # raw CBOR hex
├── unsigned-tx.tx       # TextEnvelope wrap
├── questions/Q-NNN-*.md # operator Q-files (per-witness requests)
├── answers/A-NNN-*.md   # operator A-files (witness CBOR)
├── signed-tx.hex        # attach-witness --out
├── signed-tx.tx         # envelope-signed-tx wrap
└── submit.log           # submit output (post-submission)
```

Treat each artefact as immutable once written; if you rebuild,
start a fresh `*-rebuild/` sibling rather than overwriting.

## Archive into the in-repo `transactions/` log

**Every tx that goes near the chain MUST be archived** into
`transactions/<year>/<scope>/<txid-or-slug>/` inside the repo
checkout the operator is running from. The scratch dir under
`<config.scratchDirRoot>` is working memory and disappears on
reboot; the in-repo log is the durable audit trail the registry
will eventually anchor on-chain.

Two phases — one at build, one after submission. **Never skip the
post-submission refresh.** Full procedure in
[references/transactions-log.md](references/transactions-log.md).

## Troubleshooting

See [references/troubleshooting.md](references/troubleshooting.md)
for:

- TTL pitfall — multi-owner sigs vs default validity horizon
- Chain horizon overshoot (`ResolverValidityOvershoot` / `HorizonError`) when the local node is behind
- `OutsideValidityIntervalUTxO` and the rebuild ceremony
- `tx-validate` false positive: `WithdrawalsNotInRewardsCERTS`
- Upstream metadata `registry_script.hash` typo (contingency scope)
- Witness `--expected-key-hash` mismatch — wrong vault or identity
- System-PATH `amaru-treasury-tx` lags behind the worktree; pin a `nix build` binary via `--binary`
- txId lives at `result.report.identity.txId` inside `report.json`, not at the top
- 64-byte cap on `description / justification / destinationLabel / label` — the wizard does NOT auto-chunk these

## When to escalate to a human

- Phase-1 `OutsideValidityIntervalUTxO` (TTL past): the rebuild
  path is mechanical, but confirm the operator wants to refresh,
  not abandon.
- Any `AnchorMismatch` other than the known
  `registry_script.hash` upstream typo: stop and surface — could
  be deployment drift.
- Witness hash mismatch from `--expected-key-hash`: wrong vault or
  identity selected; rename the Q-file with a `-retry` suffix and
  ask again rather than silently accepting.
- Any `submit` request — always reconfirm before broadcasting.
  Immediately after a successful submit, queue the `transactions/`
  archive refresh (rename slug→txid, add `inputs/`, signed-tx,
  submit.log, submitted.json; refresh `summary.md`). Don't defer.
