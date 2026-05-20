# `operator.json` schema

Schema for `~/.config/amaru-treasury-tx/operator.json` (or
`$XDG_CONFIG_HOME/amaru-treasury-tx/operator.json` if
`XDG_CONFIG_HOME` is set).

This file is **operator-local**: never commit it, never share it
across hosts without re-running the
[first-run interview](first-run-interview.md). It contains
references to age-encrypted vaults and may contain a Blockfrost
project_id — both deserve the `umask 077` permission discipline.

## Top-level shape

```json
{
  "schema": 1,
  "network": "mainnet | preview | preprod",
  "nodeSocket": "/abs/path/to/node.socket",
  "metadataPath": "/abs/path/to/metadata.json",
  "scopeOwners": {
    "full": {
      "<label>": "<28-byte-payment-key-hash-hex>"
    },
    "local": ["<label>", "..."]
  },
  "vaults": {
    "<owner-label>": {
      "path": "/abs/path/to/<vault>.age",
      "identity": "<label-or-hash>",
      "keyHash": "<28-byte-payment-key-hash-hex>"
    }
  },
  "walletAddress": "addr1...",
  "scratchDirRoot": "/tmp",
  "archiveTransactions": true,
  "cardanoTxToolsPath": "/abs/path/to/cardano-tx-tools | \"\"",
  "blockfrostProjectId": "<network><32hex> | \"\""
}
```

## Field reference

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `schema` | integer | yes | Currently `1`. Bumped on incompatible changes. |
| `network` | string | yes | One of `mainnet`, `preview`, `preprod`. Used for the global `--network` flag and to sanity-check the node socket magic. |
| `nodeSocket` | absolute path | yes | Exported as `CARDANO_NODE_SOCKET_PATH` before any node-talking command. Must exist and be a socket. |
| `metadataPath` | absolute path | yes | Treasury journal `metadata.json`. The `--metadata` argument every wizard takes. |
| `scopeOwners.full` | object | yes | Roster of every owner in the active metadata, label → 28-byte payment-key hash hex. Discovered from `metadataPath`, not memorized. |
| `scopeOwners.local` | string[] | yes | Subset of `scopeOwners.full` keys this operator can sign as. Empty list is valid (submit-only role). |
| `vaults` | object | when `scopeOwners.local` is non-empty | One entry per local owner. `keyHash` MUST equal `scopeOwners.full[<owner-label>]`. |
| `walletAddress` | bech32 | yes | Fuel wallet for `--wallet-addr`. Pays fees, provides collateral. |
| `scratchDirRoot` | absolute path | yes | Where per-flow scratch dirs live. Default `/tmp`. |
| `archiveTransactions` | boolean | yes | Auto-archive built / submitted txs into `transactions/<year>/<scope>/<…>/` in the active checkout. Default `true`. |
| `cardanoTxToolsPath` | absolute path | no | Local `cardano-tx-tools` checkout for `tx-inspect` / `tx-validate` / `tx-diff`. Empty string = "skip companion-tool steps". |
| `blockfrostProjectId` | string | no | Used to fetch parent tx CBORs during the post-submission archive refresh. Sensitive — never log or commit. Empty string = skip the `inputs/<parent>.cbor` step. |

## Example (preview testnet, single-owner operator)

```json
{
  "schema": 1,
  "network": "preview",
  "nodeSocket": "/var/run/cardano-node-preview/node.socket",
  "metadataPath": "/home/alice/code/amaru-treasury/journal/2026/metadata.json",
  "scopeOwners": {
    "full": {
      "core_development": "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb",
      "ops_and_use_cases": "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e",
      "network_compliance": "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1",
      "middleware": "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
    },
    "local": ["ops_and_use_cases"]
  },
  "vaults": {
    "ops_and_use_cases": {
      "path": "/home/alice/secrets/ops-vault.age",
      "identity": "alice@ops",
      "keyHash": "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
    }
  },
  "walletAddress": "addr_test1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz",
  "scratchDirRoot": "/tmp",
  "archiveTransactions": true,
  "cardanoTxToolsPath": "/home/alice/code/cardano-tx-tools",
  "blockfrostProjectId": ""
}
```

## Permissions

`umask 077` before writing. Group/other-readable mode is a smell:
the file references vault paths and may contain a Blockfrost key.

```bash
chmod 600 ~/.config/amaru-treasury-tx/operator.json
```

## Migration

If `schema` doesn't match the current spec, the skill should refuse
to use the file and ask the operator to re-run the
[first-run interview](first-run-interview.md). Don't auto-migrate
silently — schema bumps usually mean field semantics changed.
