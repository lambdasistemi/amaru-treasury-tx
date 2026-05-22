# Contract: `disburse-wizard --reference-*` flags

**Phase**: 1 (design & contracts)
**Surface**: `amaru-treasury-tx disburse-wizard` (operator CLI)

## Flag grammar

Three new repeatable flags. All are optional. A `disburse-wizard`
invocation with zero `--reference-uri` flags is unchanged from
today's behaviour.

```
--reference-uri TEXT      Reference URI (e.g. ipfs://<CID>).
                          Each occurrence opens a new reference slot.
                          Repeatable.

--reference-type TEXT     Reference @type. Default: "Other".
                          Populates the most-recently-opened slot.
                          Must follow a --reference-uri.

--reference-label TEXT    Reference human-readable label. A literal
                          " - " (space-dash-space) marks the split
                          boundary for the on-chain Metadatum chunks.
                          Populates the most-recently-opened slot.
                          Must follow a --reference-uri.
```

## Slot-opening rule

A reference slot is **opened** by `--reference-uri`. The subsequent
`--reference-type` / `--reference-label` flags populate that slot
until the next `--reference-uri` opens a new slot (or the command
ends).

| Invocation pattern | Result |
|---|---|
| No `--reference-*` flags | `references: []` (current behaviour) |
| `--reference-uri X --reference-label L` | one slot: `{uri=X, type="Other", label=L}` |
| `--reference-uri X --reference-label L --reference-uri Y --reference-label M` | two slots: `[{X,Other,L}, {Y,Other,M}]` |
| `--reference-uri X --reference-type T --reference-label L` | one slot: `{X, T, L}` |
| `--reference-label L` (no preceding `--reference-uri`) | **error** — exit 2, "--reference-label requires a preceding --reference-uri" |
| `--reference-type T` (no preceding `--reference-uri`) | **error** — exit 2, "--reference-type requires a preceding --reference-uri" |
| `--reference-uri X` (no label) | one slot: `{X, "Other", ""}` — **error** at intent-validation: "reference label is required" |
| `--reference-uri X --reference-uri Y` (no labels) | two slots, both labelless — **error** at intent-validation |
| `--reference-type T1 --reference-uri X --reference-type T2 --reference-label L` | one slot: `{X, T2, L}` (T1 errored before X was seen → exit 2) |
| `--reference-uri X --reference-type T1 --reference-type T2 --reference-label L` | one slot: `{X, T2, L}` (later --reference-type wins; not an error) |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | `intent.json` written successfully |
| 2 | CLI parser error (flag grammar / option syntax) |
| 1 | Intent validation error (chunk overflow, empty label, etc.) |

## Examples

### Single reference

```bash
amaru-treasury-tx --network mainnet disburse-wizard \
  --wallet-addr addr1q… \
  --metadata $DATA_DIR/metadata.json \
  --scope network_compliance \
  --unit usdm \
  --amount 18750000000 \
  --beneficiary-addr addr1q8qrds… \
  --description "Cyber Castellum Whitehacking Milestone 1" \
  --justification "Required to pay Cyber Castellum as vendor" \
  --destination-label "Crypto Accounting Group off-ramp wallet" \
  --extra-signer core_development \
  --validity-hours 48 \
  --reference-uri ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da \
  --reference-label "Whitehacking Agreement - Cyber Castellum 2026-03-31" \
  --out /tmp/attx-cyber-m1/intent.json \
  --log /tmp/attx-cyber-m1/wizard.log
```

### Four references (Cyber Castellum milestone 1 — the operator target)

```bash
amaru-treasury-tx --network mainnet disburse-wizard \
  --wallet-addr addr1q… \
  --metadata $DATA_DIR/metadata.json \
  --scope network_compliance \
  --unit usdm \
  --amount 18750000000 \
  --beneficiary-addr addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl \
  --description "Cyber Castellum Whitehacking Milestone 1 - 18750 USDM" \
  --justification "Required to pay Cyber Castellum as vendor; payment instruction confirmed by CAG 2026-05-21" \
  --destination-label "Crypto Accounting Group off-ramp wallet" \
  --extra-signer core_development \
  --validity-hours 48 \
  --reference-uri ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da \
  --reference-label "Whitehacking Agreement - Cyber Castellum 2026-03-31" \
  --reference-uri ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu \
  --reference-label "Invoice 3508 - Cyber Castellum Whitehacking M1" \
  --reference-uri ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga \
  --reference-label "CAG MSA - 2026-04-09" \
  --reference-uri ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm \
  --reference-label "CAG payment confirmation - Laura Dugan email 2026-05-21" \
  --out /tmp/attx-cyber-m1/intent.json \
  --log /tmp/attx-cyber-m1/wizard.log
```

## Non-changes

`withdraw-wizard`, `contingency-disburse-wizard`, `reorganize-wizard`,
`swap-wizard`, `swap-cancel` do **not** gain these flags. Their
metadata schemas differ; adding flags later is a per-wizard ticket.
