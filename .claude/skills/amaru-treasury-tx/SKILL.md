---
name: amaru-treasury-tx
description: "Operator reference for driving `amaru-treasury-tx` on Paolo's NixOS mainnet box: build, witness, assemble, inspect, validate, submit, and archive with the project's own subcommands plus `cardano-tx-tools`. Load for `amaru-treasury-tx`, `attach-witness`, `treasury-inspect`, `disburse-wizard`, `contingency-disburse-wizard`, `withdraw-wizard`, `swap-wizard`, `swap-cancel`, submitted transaction archive checks, `submit.log` completeness checks, mainnet treasury signing/submission, `/code/cardano-mainnet/`, `journal/2026/metadata.json`, the `registry_script.hash` typo, or age-encrypted witness vaults. Prefer this over hand-rolling CBOR or cardano-cli for treasury work."
---

# amaru-treasury-tx operator workflow

Tight reference for driving the treasury tx pipeline on **this machine**
(Paolo's NixOS box). Paths and sockets below are local; on a different
host substitute the equivalents.

## Golden rule

**Use the project's own subcommands. Do not hand-roll cbor2 in Python.**
The CLI ships first-class primitives for every step (envelope/de-envelope,
witness production, witness merge, validation, submission). Hand-rolled
CBOR risks subtle wire-format bugs (CBORTag 258 for sets, vkey-witness
inner vs `[0, [vkey,sig]]` shape, body-bytes-preserve invariant). Linked
memory: `[[use-repo-tool]]`.

A submit is not complete when the CLI returns a txid. It is complete only
after the on-chain txid is archived in `transactions/`, the signed tx and
`submit.log` are copied in, `submitted.json` is written, parent inputs are
fetched, and the submitted-log completeness check below reports zero
missing archives.

## Install & invoke

The published `amaru-treasury-tx.AppImage` is actually a **statically
linked self-extracting ELF** — it runs natively on NixOS without
`appimage-run` or any wrapper. `file ~/bin/amaru-treasury-tx` reads as
"ELF 64-bit LSB executable … statically linked". Just `chmod +x` and
run.

Prefer in this order:

1. **PATH binary** — `~/bin/amaru-treasury-tx` (= `/home/paolino/bin/…`).
   Just type `amaru-treasury-tx …`.
2. **DEB / RPM** at the release page — only when installing system-wide.
3. **Local `nix run` / `cabal run`** — last resort; long build path.

Confirm the version with `amaru-treasury-tx --version` before each
operator run; we ship fast.

### Update the executable (canonical pattern)

The user's standing idiom from bash history — pick the latest tag, drop
straight into `~/bin/amaru-treasury-tx`, set the execute bit:

```bash
LATEST=$(gh release view --repo lambdasistemi/amaru-treasury-tx \
              --json tagName --jq .tagName)
curl -fsSL -o ~/bin/amaru-treasury-tx \
  "https://github.com/lambdasistemi/amaru-treasury-tx/releases/download/$LATEST/amaru-treasury-tx.AppImage"
chmod +x ~/bin/amaru-treasury-tx
amaru-treasury-tx --version   # sanity check
```

Pinning to a specific tag (e.g. when reproducing an earlier signing
session):

```bash
curl -fsSL -o ~/bin/amaru-treasury-tx \
  https://github.com/lambdasistemi/amaru-treasury-tx/releases/download/v0.2.11.0/amaru-treasury-tx.AppImage
chmod +x ~/bin/amaru-treasury-tx
```

Two non-obvious bits:

- The file dropped at `~/bin/amaru-treasury-tx` keeps the *name* but
  the `.AppImage` suffix is stripped — it's still the same artefact, but
  it ends up on PATH as a single bare command, so completion and muscle
  memory both work.
- `curl -fsSL` is the right combo: `-f` fails on HTTP errors (saves you
  from chmod-ing a "404 Not Found" HTML body), `-s` silences progress,
  `-S` keeps real errors visible, `-L` follows the GitHub redirect.

Don't bother with `appimage-run` or `nix-shell -p appimage-run` for this
binary — wasted ceremony; the static ELF inside will run from any path
on this NixOS host.

## Local fixed paths

| What | Where |
| --- | --- |
| mainnet N2C socket | `/code/cardano-mainnet/ipc/node.socket` |
| corrected `metadata.json` (working tree) | `/code/amaru-treasury/journal/2026/metadata.json` |
| upstream `metadata.json` (still has typo) | `/home/paolino/amaru-treasury-upstream/journal/2026/metadata.json` |
| `amaru-treasury-tx` repo | `/code/amaru-treasury-tx-issue-172/` (issue-N worktrees alongside) |
| `cardano-tx-tools` repo | `/code/cardano-tx-tools/` |
| Amaru-aware inspect rules | `/code/cardano-tx-tools/rules/amaru-treasury.yaml` |

Always export the socket first:

```bash
export CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket
```

`--network mainnet` is the global flag; magic 764824073.

### `cardano-tx-tools` is a hard dependency — deployment strategies

`tx-inspect`, `tx-validate`, and `tx-diff` are companion executables
that ship in their own repo (`lambdasistemi/cardano-tx-tools`), **not**
inside the `amaru-treasury-tx` AppImage. Pick one strategy based on
the host's profile:

**1. Source clone + `nix run` (RECOMMENDED — required for full pipeline)**

```bash
git clone git@github.com:lambdasistemi/cardano-tx-tools.git /code/cardano-tx-tools
# or HTTPS:  https://github.com/lambdasistemi/cardano-tx-tools.git
```

This is the only strategy that exposes **`tx-validate`** (the Conway
phase-1 pre-flight against the live node) — the release artefacts
omit it. It also gives you the `rules/amaru-treasury.yaml` collapse
file the skill references everywhere. On a host that's expected to
build, sign, and submit Amaru txs, the clone is effectively mandatory.

Bump on demand (stale clones surface a "newer release available"
banner that line-splices into the inspect tree):

```bash
git -C /code/cardano-tx-tools pull --ff-only origin main
nix run /code/cardano-tx-tools#tx-inspect -- --version   # confirm
```

**2. Remote `nix run` (no clone, no tx-validate)**

```bash
nix run github:lambdasistemi/cardano-tx-tools#tx-inspect -- <args>
nix run github:lambdasistemi/cardano-tx-tools#tx-diff    -- <args>
# tx-validate intentionally not shipped via this path — use clone.
```

Useful for inspect/diff on a host that doesn't have a clone yet, e.g.
a fresh signer host that only needs to view a tx before witnessing.
Pin to a tag for reproducibility: `…/cardano-tx-tools/v0.1.6.0#…`.

**3. AppImage release (per-tool, no nix needed)**

Each release publishes self-extracting static ELFs (same shape as
`amaru-treasury-tx.AppImage`):

```bash
LATEST=$(gh release view --repo lambdasistemi/cardano-tx-tools \
            --json tagName --jq .tagName)
for tool in tx-inspect tx-diff tx-sign cardano-tx-generator; do
  curl -fsSL -o ~/bin/$tool \
    "https://github.com/lambdasistemi/cardano-tx-tools/releases/download/$LATEST/$tool-${LATEST#v}-x86_64-linux.AppImage"
  chmod +x ~/bin/$tool
done
```

Still no `tx-validate`. AppImages are the right pick for operator
hosts that aren't dev machines (no nix, no toolchain).

**4. DEB / RPM (system install)**

Each release also publishes per-tool `.deb` and `.rpm` packages at the
same path. Use when standing up a longer-lived service host where
system packaging is preferred.

```bash
curl -fsSL -O https://github.com/lambdasistemi/cardano-tx-tools/releases/download/v0.1.6.0/tx-inspect-0.1.6.0-x86_64-linux.deb
sudo dpkg -i tx-inspect-0.1.6.0-x86_64-linux.deb
```

Same caveat: **`tx-validate` is not in the release bundle**, only in
the source clone.

**5. Per-tool tag pinning for reproducibility**

When archiving a signed tx for the audit trail, the tools' version
goes into `summary.md` alongside the `amaru-treasury-tx` CLI version.
Pin the clone to a tag (`git -C /code/cardano-tx-tools checkout
v0.1.6.0`) or invoke the per-tag AppImage when rerendering historical
inspect output.

Cross-reference: the dedicated `cardano-tx-tools` skill covers the
tools themselves; that skill assumes strategy (1) — the
`/code/cardano-tx-tools/` clone location.

## Pre-flight: don't re-ask what prior runs already know

Before any wizard, **mine the history**. Wallet-addr, scope id, signer
list, and rationale conventions are recurring values living in prior
`intent.json` files and in `treasury-inspect` output. Re-prompting the
operator each time is a workflow gap, not a safety feature — placeholder
strings like `<BECH32_FUEL_ADDR>` or `<rationale: ...>` in your proposed
command mean you skipped this step.

```bash
# 1. Authoritative per-scope state (balances, UTxOs, pending orders):
amaru-treasury-tx --network mainnet treasury-inspect \
  --metadata /code/amaru-treasury/journal/2026/metadata.json

# 2. Most recent intent for any operation:
ls -t /tmp/{swap-*,attx-*,amaru-treasury-tx-issue-*}/intent.json 2>/dev/null | head -10

# 3. Reusable fields from a prior intent:
jq '{wallet: .wallet.address, scope: .scope.id, signers, rationale,
     swap: (.swap // null)}' <path>
```

### ⚠ Verify the wallet on chain before lifting it

A `.wallet.address` from a prior `intent.json` is *not* proof of
ownership — `tx-build` will happily consume any UTxO at any address;
key ownership is only checked at submit time. Before using any
candidate wallet bech32 for a real build, run **both** checks:

1. **It must be funded with usable ADA on chain.** A wallet that holds
   only NFTs/orphaned dust is a smell — most likely a test fixture.
   ```bash
   nix run github:input-output-hk/cardano-node#cardano-cli -- \
       conway query utxo --mainnet --address <bech32> --output-json \
     | jq 'to_entries | map({utxo: .key, lovelace: .value.value.lovelace})'
   ```

2. **Its payment-key hash must be a key you (or the team) can sign
   with.** Derive the payment hash and confirm it matches a known
   scope owner *or* an identity in a known vault:
   ```bash
   nix-shell -p python3Packages.bech32 --run 'python3 -c "
   from bech32 import bech32_decode, convertbits
   hrp, data = bech32_decode(\"<bech32>\")
   payload = bytes(convertbits(data, 5, 8, False))
   print(\"payment-key hash:\", payload[1:29].hex())"'
   ```
   For canonical mainnet operator flows the payment key collapses to a
   **scope owner key** — e.g. `addr1qx9aqvsf6gne…` (the network-wallet)
   resolves to `8bd03209…` = network_compliance scope owner. That match
   is what lets a 2-signer swap satisfy both the
   `approved_by_owner_and_someone_else` policy and the wallet vkey
   witness with a single witness round.

   If the payment hash is *not* a known scope owner and *not* in any
   vault on disk, **stop and ask the operator where the key is**. The
   wizard will not warn you; phase-1 validation will not warn you; you
   will only discover it on submit (or after burning a witness round).

Three things this guards against, all encountered in practice:

- **Test-fixture leakage.** `addr1q802wxt6cg6aw0nl0vdzfxa…` is the wallet
  in every `test/fixtures/swap/intent.json`. It has accidentally
  accumulated real ADA on mainnet but the signing key exists on no
  operator host. Lifting from `/tmp/swap-{088,091}-final/intent.json`
  (which are themselves test-shaped builds) silently propagates it.
- **Misleading rules-file labels.** `cardano-tx-tools/rules/amaru-treasury.yaml`
  has historically labelled the fixture as "amaru.network-wallet" —
  tx-inspect's rule-collapsed output is *not* a chain-side guarantee of
  ownership.
- **Stale operator wallet.** Even when the wallet really is operator-
  owned, the operator may have rotated to a new bech32. Always
  cross-check that the bech32 you're about to commit a build to still
  appears in current `treasury-inspect` or the latest *submitted* tx,
  not just a /tmp build artefact.

Fields that almost never change between runs of the same op (look up,
don't ask):

| Field | Source | Re-ask only when |
| --- | --- | --- |
| `--wallet-addr` | `.wallet.address` of last intent for same scope | fuel wallet is rotated |
| `signers` / `--extra-signer` | `.signers[]` of last intent of same op shape | co-signer roster changes |
| `--metadata` | always `/code/amaru-treasury/journal/2026/metadata.json` on this box | never |
| `--scope` | "network treasury" → `network_compliance`, etc. (operator phrasing maps unambiguously) | genuinely ambiguous phrasing |
| `rationale.event` | `"disburse"` for swap / disburse / contingency-disburse flows | never on these flows |
| `rationale.label` | `"Swap ADA<->USDM"` for swaps; flow-specific for others | never on canonical flows |
| `rationale.destinationLabel` | `"<Scope> treasury"` matching `--scope` | never |

What you genuinely still ask the operator (these are the real
decisions):

- size: `--usdm <N>` / `--all-ada`, plus `--split` or `--chunk-usdm`
- price: `--min-rate` (or `--ada-usdm` + `--slippage-bps`, or
  `swap-quote --price-source coingecko-ada-usdm`)
- `rationale.description` — 1-line "what" (size + rate + counterparty)
- `rationale.justification` — 1-line "why" (vendor, mandate, deadline)
- any non-default `--extra-signer …` beyond the historical roster
- final go/no-go before `submit`

### Swap signer roster is a CHAIN-SIDE requirement, not a preference

⚠ **`swap-wizard` ships a footgun here.** Its default `signers` list is
the scope owner *only*. The on-chain permissions validator
(`validators/permissions.ak:59-64`) rejects this for any swap:

```aiken
SweepTreasury | Disburse { .. } ->
  approved_by_owner_and_someone_else(self, scope, ...)
```

A swap is encoded as `Disburse`, and the policy is "scope owner **plus
at least one other** scope owner" (`docs/permissions.md`). An intent
built without `--extra-signer …` will assemble and attach witnesses
cleanly, then be rejected phase-2 at submission with the permissions
script failing.

**Always pass `--extra-signer <other-scope>` for swap-wizard / disburse
flows.** Pick any other scope owner; recent practice uses
`core_development` or `ops_and_use_cases`. Disburse flows for the
**contingency** treasury go further — all four scope owners must
co-sign (`docs/permissions.md`).

`reorganize` is the only treasury op that the validator accepts with
just the scope owner; everything else needs at least two.

Tracked: `lambdasistemi/amaru-treasury-tx#179` — when fixed, `swap-wizard`
will refuse to emit a single-signer intent for disburse-flavored ops.

### Rule of thumb

If a proposed command contains a placeholder, stop and re-derive it from
the discovery commands above. The operator's mental model is "propose a
complete command, ask me only what's genuinely new"; bare placeholders
violate that.

Linked memory: `[[feedback_wizard_vs_stupid_command]]`,
`[[feedback_menus_from_data]]`.

## Canonical pipeline

```text
intent.json  --tx-build-->  unsigned-tx.hex  --envelope-tx-->  unsigned-tx.tx
                                  |
                                  v
                  ★ tx-inspect + tx-validate ★
                                  |
                                  v
                          [collect N detached witnesses,
                           one per signer — via `witness` or operator host]
                                  |
                                  v
unsigned-tx.hex + witnesses --attach-witness--> signed-tx.hex --envelope-signed-tx--> signed-tx.tx
                                  |
                                  v
                  ★ tx-inspect + tx-validate ★
                                  |
                                  v
                          submit (only on go)
                                  |
                                  v
              archive into transactions/<year>/<scope>/<txid>/
              (signed-tx, submit.log, submitted.json, inputs/, refresh summary.md)
```

### Inspect is mandatory at every state transition

Every time the on-disk artefact changes — fresh build, witness attached,
TTL rebuild — re-run `tx-inspect` (always with the Amaru rules) **and**
`tx-validate`, in that order, before showing the operator anything.

- **After `tx-build`:** confirm the inputs/outputs/datums/signers match
  what the wizard log claimed. The wizard can produce a clean
  intent.json that builds into a tx with surprising change splits if
  the wallet UTxO set isn't what you expected. Catch surprises here,
  not after a witness round.
- **After `attach-witness`:** the body bytes are byte-identical to the
  pre-sign body (the whole point of attach-witness), so the tree looks
  unchanged — but `tx-validate` now reports `witness_completeness_count`
  including the just-attached witnesses. The expected value post-attach
  is `0`; anything else means a vkey witness is still missing (could be
  the wallet input's payment-key sig, see the wallet-ownership pre-flight
  above).
- **Pre-submit:** one final inspect+validate immediately before
  `submit`, even if nothing has been edited since the previous one —
  in case a referenced UTxO got spent by an unrelated tx, or the chain
  advanced past `invalidHereafter`.

Skipping any of these "because the previous one was clean" is how
silent regressions get submitted. Three inspect+validate rounds per tx
is the floor, not a ceiling.

### Operator-facing brief: dispatch a fresh subagent, do not write it yourself

Mechanical inspection (running `tx-inspect` / `tx-validate`, parsing
the tree, reading `report.json`) is the orchestrator's job. The
**operator-facing pre-submit summary** — the narrative that walks
through the swap economics, slippage, fill probability, net deliverables,
and the go/no-go recommendation — must be produced by a **fresh
subagent with no prior conversation context**.

Why: the orchestrator has been arguing about flag choices, wallet
swaps, witness rounds — its brief will rationalise whatever it built.
A subagent that reads only the on-disk artefacts gives an independent
read and catches things like "the floor rate is below the bottom of
recent execution" or "the signed body disagrees with the archive
summary.md".

Dispatch pattern (the orchestrator launches; the subagent reads cold):

```text
Goal: pre-submit operator brief for an Amaru treasury tx.
Inputs (read these only, ignore the conversation):
  /tmp/attx-<issue>/<flow>/signed-tx.tx
  /tmp/attx-<issue>/<flow>/intent.json
  /tmp/attx-<issue>/<flow>/report.json
  /tmp/attx-<issue>/<flow>/wizard.log
  /tmp/attx-<issue>/<flow>/build.log
  /tmp/attx-<issue>/sundae-market-scan/report.md   # if a swap
  <repo>/transactions/<year>/<scope>/<slug>/summary.md
  <repo>/transactions/README.md
  /code/amaru-treasury/docs/permissions.md         # validator policy
Tools: tx-inspect (with --rules), tx-validate (live n2c socket), jq, awk
Output: ~400-600 word markdown brief with:
  1. one-paragraph plain-English summary
  2. inputs/outputs ledger (every UTxO, value conservation check)
  3. rate economics vs current mid + recent execution band
  4. constant-product slippage model for this size
  5. net deliverables (USDM arriving, ADA consumed, change destinations)
  6. risk checks (TTL, signer roster vs on-chain policy, surprises)
  7. provenance (CLI version, predicted txid, validation status)
  8. independent go/no-go recommendation with reason
Write to <rundir>/pre-submit-brief.md AND print to final message.
```

Show the subagent's brief to the operator verbatim — don't paraphrase,
don't second-guess. If the brief disagrees with the orchestrator's
read, surface the disagreement instead of glossing over it.

This applies to every tx that's about to be submitted, not just swaps.
For disburses / withdrawals / contingency the "economics" section
narrows to "what's being moved and from/to where", but the
independent-reader requirement is the same.

### Subcommand cheat sheet

Run `amaru-treasury-tx <verb> --help` for the canonical flag list. Common
verbs and the role each plays:

- **Wizards** (produce a unified `intent.json`):
  `disburse-wizard`, `contingency-disburse-wizard`, `withdraw-wizard`,
  `swap-wizard`, `swap-cancel`. All take `--wallet-addr`, `--metadata`,
  scope/amount/rationale flags, optional `--validity-hours`, write
  `intent.json` and a `--log`.
- `tx-build --intent intent.json --out unsigned-tx.hex
  --report report.json --log build.log` — pure builder; emits raw CBOR
  hex.
- `envelope-tx` / `envelope-witness` / `envelope-signed-tx` — wrap raw
  hex into a Conway TextEnvelope (`Tx ConwayEra` / `TxWitness ConwayEra`).
- `de-envelope` — inverse: TextEnvelope → raw CBOR hex on stdout.
- `witness --tx <unsigned> --vault <age> --identity <label-or-hash>
  --expected-key-hash <hash> --out <a-file-or-hex>` — produce one
  detached `[vkey, sig]` witness from an age-encrypted vault.
- `vault create …` — make a new age-encrypted vault from a signing key.
- `attach-witness --tx unsigned-tx.hex --witness HEX --witness HEX …
  --out signed-tx.hex` — merge any number of detached vkey witnesses
  into the unsigned tx. Accepts both raw `[vkey, sig]` and the
  `[0, [vkey, sig]]` Shelley envelope form (`lib/Amaru/Treasury/Tx/AttachWitness.hs`
  decoder handles both).
- `treasury-inspect` — read-only report of treasury balances + pending
  SundaeSwap orders per scope.
- `submit --tx signed-tx.hex` — broadcast through the N2C socket.
  **Accepts the raw CBOR hex form only**, not the TextEnvelope (`.tx`).
  Passing `signed-tx.tx` returns `invalid base16 in unsigned transaction:
  invalid character at offset: 0` (the leading `{` of the envelope). If
  you only have the envelope, pipe it through `de-envelope` first or use
  the `.hex` sibling that `attach-witness` already produced.
  Only after explicit operator approval; never submit on your own.

### Owner identifier conventions

In wizard logs and inspect output the four owners surface as their
28-byte payment-key hashes. The standing mainnet allocation:

| Hash prefix | Scope owner |
| --- | --- |
| `7095faf3` | `core_development` |
| `f3ab64b0` | `ops_and_use_cases` |
| `97e0f6d6` | `middleware` |
| `8bd03209` | `network_compliance` |

Required-signers in the tx body are reported in the order the build
emitted them, not the prefix order above.

## Companion tools: cardano-tx-tools

Invoke via `nix run /code/cardano-tx-tools#<app> -- …`.

- **tx-inspect** — render the tx body as a tree. Use the Amaru rules to
  collapse known addresses into labels:
  ```bash
  nix run /code/cardano-tx-tools#tx-inspect -- \
      --rules /code/cardano-tx-tools/rules/amaru-treasury.yaml \
      /tmp/attx-172/.../signed-tx.tx
  ```
  Without `--rules`, you'll see raw script-hash bytes for treasury
  addresses; with rules, you'll see `amaru-treasury.network_compliance.account`
  etc.
- **tx-validate** — Conway phase-1 pre-flight against the live node:
  ```bash
  nix run /code/cardano-tx-tools#tx-validate -- \
      --input signed-tx.hex \
      --n2c-socket "$CARDANO_NODE_SOCKET_PATH" \
      --network-magic 764824073 \
      --output human
  ```
  ⚠ Input must be raw CBOR hex, not a TextEnvelope; pipe through
  `de-envelope` if you only have the `.tx`.

  **KNOWN false positive — `WithdrawalsNotInRewardsCERTS`:** every
  Amaru tx uses a withdraw-zero against the permissions script
  (`2810b46b…`) to trigger the multi-owner check. `tx-validate` seeds
  only pparams + UTxO from `n2c` and leaves the rewards UMap empty
  (see `seedNewEpochState` in
  `/code/cardano-tx-tools/src/Cardano/Tx/Validate.hs:132-143`), so it
  reports every such withdrawal as "not in rewards" even when the
  permissions stake credential is genuinely registered on chain.
  Confirm with cardano-cli (below) before treating it as real. Tracked
  upstream as `lambdasistemi/cardano-tx-tools#61`.
- **tx-diff** — compare two transactions; ideal for proving "I only
  refreshed TTL" between an expired build and its rebuild:
  ```bash
  nix run /code/cardano-tx-tools#tx-diff -- \
      --collapse-rules /code/cardano-tx-tools/rules/amaru-treasury.yaml \
      old.tx new.tx
  ```
  Both TextEnvelope or raw hex inputs are accepted.

## Standard runtime / log dir layout

Set up by issue 172 (tx log dir). One directory per build, conventional
file names so downstream tools and human review both work:

```
/tmp/attx-<issue>/<flow-name>/
├── wizard.log           # contingency-disburse-wizard step trace
├── intent.json          # unified intent (wizard --out)
├── build.log            # tx-build step trace
├── report.json          # deterministic build report (tx-build --report)
├── unsigned-tx.hex      # raw CBOR hex
├── unsigned-tx.tx       # envelope (envelope-tx wrap of the above)
├── questions/Q-NNN-*.md # operator Q-files (per-witness requests)
├── answers/A-NNN-*.md   # operator A-files (witness CBOR or TextEnvelope)
├── signed-tx.hex        # attach-witness --out
└── signed-tx.tx         # envelope-signed-tx wrap
```

Treat each artefact as immutable once written; if you need to rebuild,
start a fresh `*-rebuild/` sibling rather than overwriting.

## Archive into the in-repo `transactions/` log

Every tx that goes near the chain MUST be archived into
`transactions/<year>/<scope>/<txid-or-slug>/` inside the
`amaru-treasury-tx` repo. The scratch dir under `/tmp/` is operator
working memory and disappears on reboot; the in-repo log is the
durable audit trail that #163 will hash-commit on-chain. Authoritative
contract for the per-entry artefact set is
`transactions/README.md`. Two write phases — one at build, one after
submission. **Never skip the post-submission refresh.**

### At build time — log a pre-submission entry

After the wizard + `tx-build` succeed, copy the scratch artefacts
into a slug-named directory:

```
transactions/<year>/<scope>/<YYYY-MM-DD-action-target-slug>/
├── intent.json          # copy of intent.json (omit only if no wizard, e.g. swap-cancel)
├── tx.cbor              # copy of unsigned-tx.hex (single hex line, no JSON wrap)
├── tx.envelope.json     # copy of unsigned-tx.tx
├── build.log
├── wizard.log           # if the build came through a wizard
├── report.json
└── summary.md           # mark status: rebuilt; awaiting N witnesses
```

Add one bullet under `CHANGELOG.md`'s `## Unreleased > ### Features`
and commit (bisect-safe; do NOT push). The CLI version (e.g.
`amaru-treasury-tx 0.2.11.0`) goes into both `summary.md` and the
commit body — operators correlate by it.

### After submission — refresh the entry

Once the tx is on chain, promote the entry:

1. `git mv transactions/<year>/<scope>/<slug>
        transactions/<year>/<scope>/<txid>` — rename to the immutable
   on-chain txid (README naming convention).
2. Add the **verifiable parent bundle** `inputs/<parent-txid>.cbor`
   for every input txid — inputs, collateral, and reference inputs
   decoded from the tx body. Fetch via Blockfrost `/txs/{hash}/cbor`;
   mainnet project_id lives in the operator's credential store
   (do not commit it). Filename invariant:
   `blake2b-256(canonical(body)) == <txid>`.
3. Drop the signed artefacts from the scratch dir: `signed-tx.hex`,
   `signed-tx.tx`, `submit.log`.
4. Write `submitted.json` —
   `{ txid, block, slot, block_time, timestamp, submitter,
     fee_lovelace, valid_contract }`. Block + slot from Blockfrost
   `/txs/{hash}` or `cardano-cli query tip` + `tx-id` cross-check.
5. Rewrite `summary.md`: status → submitted, add on-chain receipt
   block, witness collection trail, refs to any companion entries
   (e.g. cancelled order, pending rebuild).
6. Update the matching `## Unreleased` bullet — edit in place, or
   split it if the original bullet covered multiple pending txs
   (one ends up submitted, the other still pending).

One bisect-safe commit per refresh. `submitted.json` is the marker
that the entry is "done"; presence of only `tx.cbor`/`intent.json`
without `submitted.json` means pre-submission.

### Submitted-log completeness audit

When the operator asks "are they all there?", the source of truth is
the set of local `submit.log` artefacts from the operator run
directories, not every chain transaction that touched the treasury
address. Address history includes unrelated funding transactions and
Sundae scoop/fill transactions that are not `amaru-treasury-tx submit`
outputs.

Before marking a submit session complete, updating a PR body, or
claiming the archive is current:

1. Enumerate the operator scratch roots used in the session
   (`/tmp/attx-<issue>/...`, explicit rebuild dirs, and any
   `/tmp/amaru-treasury-tx-*` rundirs the operator named).
2. Extract every txid from `submit.log`. Treat each one as a submitted
   transaction that must have a txid-named entry somewhere under
   `transactions/<year>/<scope>/`.
3. Verify each matching entry has `submitted.json`, `submit.log`,
   `signed-tx.hex`, `signed-tx.tx`, `summary.md`, and `inputs/*.cbor`.
4. Cross-check `submitted.json.txid` and the final `submit.log` txid
   against the directory name. If chain access is available, compare
   `signed-tx.hex` to Koios/Blockfrost tx CBOR for that txid.
5. Only then say the submit archive is complete. Any missing txid gets
   archived in the same PR before review.

Do not classify address-touching but non-submitted transactions as
missing operator archives unless there is a corresponding local
`submit.log` or another explicit operator receipt.

### Decode parent txids from a tx body

```bash
nix-shell -p python3Packages.cbor2 --run "python3 - <<PY
import cbor2, io
hex_str = open('transactions/.../tx.cbor').read().strip()
fp = io.BytesIO(bytes.fromhex(hex_str))
fp.read(1)   # array header
body = cbor2.CBORDecoder(fp).decode()
parents = set()
for k in (0, 13, 18):    # inputs, collateral, reference inputs (Conway)
    if k in body:
        for entry in body[k]:
            parents.add(entry[0].hex())
print('\n'.join(sorted(parents)))
PY"
```

Typical count for a treasury tx is 2–10 parents (one wallet input,
one treasury input, ~3–4 reference inputs for permissions/registry/
scopes/treasury scripts). Outside that range is a smell — sanity check
before fetching. Also: when feeding the parent list to a `while read`
loop, make sure the file ends with a newline or the last line is
silently skipped.

### Why both phases matter

The build-time entry captures the **intent and exact body bytes the
witnesses sign** — invaluable if the tx expires and is rebuilt: the
pre-submission directory becomes the audit trail showing "this is the
bundle the N owners saw." The post-submission refresh promotes the
entry to "happened on chain" and locks the directory name to the
immutable txid. Together they make `transactions/` a complete
operator record independent of the scratch dir.

If the tx expires and you rebuild, do NOT delete the pre-submission
entry — the rebuild lives at a sibling slug (`…-rebuild/`); the
expired bundle stays archived as historical context. `tx-diff`
between the two proves "only TTL changed."

## Age-encrypted vaults

Owners hold their signing keys inside age-encrypted *witness vaults*.
The `witness` subcommand decrypts in memory, signs the tx body hash, and
emits raw `[vkey, sig]` CBOR hex.

```bash
amaru-treasury-tx --network mainnet \
    witness \
      --tx /tmp/.../pending.tx \
      --vault /code/amaru-treasury-issue-128/treasury.vault.age \
      --identity 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 \
      --expected-key-hash 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 \
      --out /tmp/.../answers/A-003-witness-8bd03209.md
```

- `--identity` accepts a label or a 28-byte hex hash. Passing the hash
  plus `--expected-key-hash` belt-and-braces against picking the wrong
  identity from a multi-identity vault.
- `--vault-passphrase-fd FD` lets you script the passphrase; without it
  the tool prompts on the tty.
- Output is **raw** `[vkey (32), sig (64)]` CBOR hex — exactly what
  `attach-witness --witness HEX` expects (`envelope-witness` wraps it
  if you need a Conway `TxWitness ConwayEra` envelope instead).

Vault discovery: `*.age` files. Candidates on this box have included
`/code/amaru-treasury-issue-128/treasury.vault.age` and per-epic funding
vaults like `/tmp/epic-156-slice3-registry-stake/phases/registry-stake/funding.vault.age`.

## Gotchas

### TTL pitfall — multi-owner sigs vs default horizon

`--validity-hours` is optional and the wizards default to "the chain's
current horizon" — typically only ~12 h. That's not enough for a 4-of-4
owner signature round-trip across timezones; one expired tx wastes a
whole signing round. **Always pass `--validity-hours 24` (single round)
or `--validity-hours 48` (multi-day) when sigs span humans.**

If a tx has already expired, you'll see this in `tx-validate`:

```text
OutsideValidityIntervalUTxO (ValidityInterval {invalidHereafter = SJust (SlotNo …)}) (SlotNo <tip>)
```

There's no rescue — rebuild from the same `intent.json` with a fresh
TTL; the inputs/outputs stay byte-identical and witness collection
restarts. Confirm with `tx-diff` that the only change is
`body.validityInterval.invalidHereafter`.

### Upstream metadata.json typo (contingency scope)

`pragma-org/amaru-treasury` carries a typo on commit `d021bf27` (KtorZ,
2026-02-13). `journal/2026/metadata.json` line 85, contingency scope,
`registry_script.hash` is missing the trailing `8`:

```
metadata says: 7d275cf8c09fd91e73879993ef13cb73915196478d5e3777992f988   (27.5 B, broken)
on-chain     : 7d275cf8c09fd91e73879993ef13cb73915196478d5e3777992f9888 (28 B, correct)
```

`/code/amaru-treasury/` has the 1-line fix as **uncommitted working-tree
edit** (not pushed upstream). Other local clones
(`amaru-treasury-upstream`, `swap-cancel-atleast-2`, `swap-experiment`)
still carry the typo. **For any contingency-disburse run, point `--metadata`
at `/code/amaru-treasury/journal/2026/metadata.json`**. The wizard otherwise
aborts with `AnchorMismatch "registry_script.hash" (Just Contingency) …`.

Not all flows hit this verification path — `disburse-wizard` and
`withdraw-wizard` for non-contingency scopes can pass either file.

### tx-validate false positive

Already covered above; restating because it's the noisiest gotcha.
**`WithdrawalsNotInRewardsCERTS` is a false positive for every
Amaru tx with a withdraw-zero entry.** Verify with cardano-cli:

```bash
nix run github:input-output-hk/cardano-node#cardano-cli -- \
    conway query stake-address-info --mainnet \
    --address <stake_script1 bech32>
```

A response with `stakeRegistrationDeposit: 2000000` means the credential
**is** registered; `tx-validate`'s objection is then bogus.

### Wallet bech32 from raw CBOR address bytes

When you only have the raw 57-byte address bytes from a tx body (header
`0x01` for base addr + 28 B payment + 28 B stake on mainnet), derive the
bech32 via `python3Packages.bech32`:

```bash
nix-shell -p python3Packages.bech32 --run 'python3 -c "
from bech32 import bech32_encode, convertbits
payload = bytes.fromhex(\"01<payment-hash><stake-hash>\")
print(bech32_encode(\"addr\", convertbits(payload, 8, 5)))
"'
```

For reward (stake) addresses use header `0xe1` (key-on-stake mainnet) or
`0xf1` (script-on-stake mainnet) and `hrp=\"stake\"`.

## Quick recipes

### Emit the witness commands as soon as the body is built

**Immediately after `tx-build` + `envelope-tx`, surface the per-signer
`amaru-treasury-tx witness …` invocations** — don't wait for the
operator to ask "give me the command to sign". The `signers[]` list in
the intent is the canonical roster; the vault on this box is
`/code/amaru-treasury-tx-issue-128/treasury.vault.age`; outputs land in
`<rundir>/answers/A-NNN-witness-<prefix>.tx`.

⚠ **Inline the `mkdir -p <out-dir>` into every witness command.** The
`witness` subcommand opens its `--out` temp file BEFORE prompting for
the vault passphrase. If the directory doesn't exist, the tool takes
the passphrase, then crashes with an uncaught `IOException` — the
passphrase entry is wasted and the operator has to retype it on retry
(tracked: `lambdasistemi/amaru-treasury-tx#182`). Operators routinely
copy one command out of a multi-command block and run it in isolation
*without* the leading `mkdir`; putting the `mkdir` inside each command
makes that habit harmless.

Boilerplate generator (paste into the build dir after `tx-build`):

```bash
RUNDIR=/tmp/attx-<issue>/<flow>
VAULT=/code/amaru-treasury-tx-issue-128/treasury.vault.age
ANSWERS="$RUNDIR/answers"
i=0
for hash in $(jq -r '.signers[]' "$RUNDIR/intent.json"); do
  i=$((i+1))
  prefix=${hash:0:8}
  printf 'mkdir -p %s && \\\n' "$ANSWERS"
  printf 'amaru-treasury-tx --network mainnet witness \\\n'
  printf '  --tx %s/unsigned-tx.tx \\\n' "$RUNDIR"
  printf '  --vault %s \\\n' "$VAULT"
  printf '  --identity %s \\\n' "$hash"
  printf '  --expected-key-hash %s \\\n' "$hash"
  printf '  --out %s/A-%03d-witness-%s.tx\n\n' "$ANSWERS" "$i" "$prefix"
done
```

Each emitted block is self-contained: `mkdir -p … && amaru-treasury-tx
witness …`. Pasting any single block in isolation works without the
operator having to run a separate `mkdir` first.

The vault prompts for the passphrase on the tty, witnesses drop into
`answers/`, and `attach-witness` merges them. `--expected-key-hash` is
belt-and-braces against the wrong identity being selected from a
multi-identity vault.

### One-shot rebuild (TTL refresh from same intent)

If you have the wizard's `intent.json` already, you can skip the wizard
and just call `tx-build` again — chain horizon is re-queried, fees are
re-evaluated.

### Inspect any tx in operator-friendly form

```bash
nix run /code/cardano-tx-tools#tx-inspect -- \
    --rules /code/cardano-tx-tools/rules/amaru-treasury.yaml \
    path/to/signed-or-unsigned.tx
```

### Round-trip a witness envelope into the inner CBOR hex

`amaru-treasury-tx de-envelope < witness.tx` will surface the inner hex
ready to pass to `attach-witness --witness …`. Works for either the raw
inner form or the `[0, [vkey, sig]]` Shelley wrap.

### Verify body-bytes invariant after assembly

`attach-witness` preserves the body verbatim (it's the whole point), so
the txid recomputed from the signed tx must equal the original body
hash. If the operator brief asks you to verify, recompute via the
tool's own `de-envelope | head` of body bytes and a blake2b-256. The
expected workflow doesn't require this — `attach-witness` is trusted.

## When to escalate to a human

- Phase-1 `OutsideValidityIntervalUTxO` (TTL past): the rebuild path is
  mechanical, but confirm operator intent first (sometimes they want to
  abandon, not refresh).
- Any `AnchorMismatch` other than the known `registry_script.hash` typo:
  stop and surface — could be a deployment drift, not a typo.
- Witness hash mismatch from `--expected-key-hash`: a wrong vault or
  wrong identity was selected; rename the Q-file with a `-retry`
  suffix and ask again rather than silently accept.
- Any `submit` request — always reconfirm with the operator before
  broadcasting. Immediately after a successful submit, queue and finish
  the `transactions/` archive refresh (rename slug→txid, add inputs/,
  signed-tx, submit.log, submitted.json; refresh summary.md), then run
  the submitted-log completeness audit above. Operators rely on this
  happening in the same operator session as the submit; don't defer it.
