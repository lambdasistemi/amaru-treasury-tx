# First-run interview

The first time the operator skill runs on a host, it walks the
operator through these questions and writes the answers to
`~/.config/amaru-treasury-tx/operator.json` (or
`$XDG_CONFIG_HOME/amaru-treasury-tx/operator.json` if `XDG_CONFIG_HOME`
is set). After that, every recipe in the skill resolves
`<config.field>` placeholders from this file silently.

If the file already exists, **do not re-ask** any of these. Read it
once at session start and reuse the answers for the rest of the
session. Editing the file directly is fine; the skill re-reads it on
the next session.

## Questions

Ask one at a time. Each question lists the JSON key it populates,
the canonical default (where one exists), and the validation rule.

### 1. Network — `network`

> Which Cardano network are you operating against?

Accept `mainnet`, `preview`, or `preprod`. Default: `mainnet`.

Validation: the `treasury-inspect` handshake will refuse to talk
to a node whose magic doesn't match this value, so a wrong answer
will fail loudly the first time you call any wizard.

### 2. Cardano-node N2C socket — `nodeSocket`

> Where is the cardano-node socket you'll use? (absolute path)

Default suggestion: `/var/run/cardano-node/node.socket` if the
operator runs cardano-node as a systemd service, otherwise prompt
freely.

Validation: `test -S "$nodeSocket"` (exists, is a socket).

### 3. Treasury metadata file — `metadataPath`

> Absolute path to the `metadata.json` for the active treasury
> (typically a clone of [`pragma-org/amaru-treasury`](https://github.com/pragma-org/amaru-treasury) at
> `journal/<year>/metadata.json`).

No default — operators clone the repo wherever they keep
infrastructure. Confirm the file exists and the year matches the
operator's expectation.

Heads-up: upstream `pragma-org/amaru-treasury` has a known typo on
the contingency scope's `registry_script.hash`. If the operator is
running against mainnet and intends to do *any* contingency
operation, ask whether they have the fix applied locally or
upstream. See
[references/troubleshooting.md](troubleshooting.md#upstream-metadata-typo).

### 4. Scope-owner roster — `scopeOwners`

> Which scope owners do you have witness keys for? Give one entry
> per owner you can sign as: a label (e.g. `core_development`,
> `ops_and_use_cases`, `network_compliance`, `middleware`,
> `contingency`) and the 28-byte payment-key hash from
> `treasury-inspect`.

For the full roster (including owners the operator can't sign as
themselves), discover from the `metadata.json` — it lists every
scope and its owner key hash. Store the discovered roster as
`scopeOwners.full`; store the operator-signs-as subset as
`scopeOwners.local`.

JSON shape:

```json
{
  "scopeOwners": {
    "full": {
      "<label>": "<28-byte-payment-key-hash-hex>",
      "...": "..."
    },
    "local": ["<label>", "..."]
  }
}
```

### 5. Witness vaults — `vaults`

> For each owner label in `scopeOwners.local`, give the absolute
> path to the age-encrypted vault that holds their signing key,
> and the identity label (if the vault holds multiple identities).

Validation: `test -f "$path"`, file should end with `.age`. The
`identity` field can be a human-readable label or a 28-byte hex
hash — both work with `amaru-treasury-tx witness --identity`.

JSON shape:

```json
{
  "vaults": {
    "<owner-label>": {
      "path": "/abs/path/to/<vault>.age",
      "identity": "<label-or-hash>",
      "keyHash": "<28-byte-payment-key-hash-hex>"
    }
  }
}
```

`keyHash` must match `scopeOwners.full[<owner-label>]` —
re-confirm before writing.

### 6. Fuel wallet — `walletAddress`

> Which fuel wallet (bech32 address starting `addr1…`) pays fees
> and provides collateral for transactions you build? This is the
> wallet `--wallet-addr` argument every wizard takes.

No default — site-specific. Confirm by running:

```bash
amaru-treasury-tx --network <config.network> treasury-inspect \
  --metadata <config.metadataPath>
```

and verifying the wallet shows up as fundable.

### 7. Scratch directory root — `scratchDirRoot`

> Where do you want per-flow scratch directories
> (`wizard.log`, `intent.json`, `unsigned-tx.hex`, witness Q/A
> files, signed-tx, submit.log) to live? Default: `/tmp`.

Validation: directory exists and is writable.

The skill will create
`<scratchDirRoot>/<short-flow-name>-<YYYYMMDD-HHMMSS>/` per
operation.

### 8. In-repo archive — `archiveTransactions`

> When a tx is built or submitted, should the skill automatically
> archive it into `transactions/<year>/<scope>/<…>/` inside the
> repo you're running from? Default: `true`.

This is the durable audit trail described in
[references/transactions-log.md](transactions-log.md). Setting it
to `false` means the operator is committing to archive manually
each time. Recommend leaving it on.

### 9. (optional) `cardano-tx-tools` checkout — `cardanoTxToolsPath`

> Do you have a local checkout of
> [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)?
> If yes, give the absolute path. If not, leave empty — the
> pipeline will still work without it, just with less pretty
> inspection output.

Validation: if non-empty, the path must contain a `flake.nix` and
either `rules/amaru-treasury.yaml` or a `rules/` directory.

### 10. (optional) `blockfrostProjectId` — `blockfrostProjectId`

> Do you have a Blockfrost project_id for this network? Used to
> fetch parent tx CBORs when refreshing the in-repo archive after
> submission. If empty, the post-submission refresh will skip the
> verifiable-bundle `inputs/<parent>.cbor` step (operator can
> backfill later).

Sensitive — never echo, log, or commit this value. The skill
reads it from the config at use time and never writes it to
status logs.

## Confirming and writing

After all answers are collected, **show the assembled JSON back to
the operator** for confirmation before writing. Mask the
`blockfrostProjectId` to `mainnet***` style in the confirmation.

Write atomically:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/amaru-treasury-tx"
umask 077
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/amaru-treasury-tx/operator.json.tmp" <<'EOF'
<assembled JSON>
EOF
mv "${XDG_CONFIG_HOME:-$HOME/.config}/amaru-treasury-tx/operator.json".{tmp,}
```

`umask 077` so the file is readable only by the operator (it
contains Blockfrost project_id and witness-vault paths). The
schema sits in
[references/operator-config-schema.md](operator-config-schema.md).

## Re-running the interview

Operators delete or rename
`~/.config/amaru-treasury-tx/operator.json` to redo the interview
(e.g. after rotating a vault, changing networks, or moving the
treasury metadata). The skill always re-checks for the file at
session start — no other invalidation mechanism exists.
