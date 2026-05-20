# In-repo `transactions/` archive

Every transaction that goes near the chain MUST be archived into
`transactions/<year>/<scope>/<txid-or-slug>/` inside the
`amaru-treasury-tx` checkout the operator is running from. The
scratch dir under `<config.scratchDirRoot>` is operator working
memory and disappears on reboot; the in-repo log is the durable
audit trail.

Authoritative contract for the per-entry artefact set is
`transactions/README.md` in the repo root. This document covers the
*workflow* for writing entries; the README covers the *contract*
for what an entry contains.

**Two phases — one at build, one after submission.** Never skip the
post-submission refresh.

## At build time — log a pre-submission entry

After the wizard + `tx-build` succeed, copy the scratch artefacts
into a slug-named directory:

```
transactions/<year>/<scope>/<YYYY-MM-DD-action-target-slug>/
├── intent.json          # copy of intent.json (omit if no wizard, e.g. swap-cancel)
├── tx.cbor              # copy of unsigned-tx.hex (single hex line, no JSON wrap)
├── tx.envelope.json     # copy of unsigned-tx.tx
├── build.log
├── wizard.log           # if the build came through a wizard
├── report.json
└── summary.md           # narrative; status: rebuilt; awaiting N witnesses
```

Slug shape: `<YYYY-MM-DD>-<action>-<target-summary>[-rebuild]`.
Examples:

- `2026-05-20-disburse-205k-network-compliance`
- `2026-05-20-swap-cancel-59e10ca5-network-compliance-rebuild`
- `2026-05-21-withdraw-treasury-rewards-core-development`

The CLI version (`amaru-treasury-tx --version`) goes into both
`summary.md` and the commit body — operators correlate by it.

Add one bullet under `CHANGELOG.md`'s
`## Unreleased > ### Features` and commit (bisect-safe; do **not**
push without operator approval).

## After submission — refresh the entry

Once the tx is on chain, promote the entry. One bisect-safe commit
per refresh.

1. `git mv transactions/<year>/<scope>/<slug>
        transactions/<year>/<scope>/<txid>` — rename to the
   immutable on-chain txid per the README naming convention.
2. Add the **verifiable parent bundle** `inputs/<parent-txid>.cbor`
   for every input txid — inputs, collateral, and reference inputs
   decoded from the tx body. Fetch via Blockfrost
   `/txs/{hash}/cbor` using `<config.blockfrostProjectId>`. Filename
   invariant: `blake2b-256(canonical(body)) == <txid>`. (If the
   operator did not provide a Blockfrost key, skip this step and
   note it as missing in `summary.md` — they can backfill later.)
3. Drop the signed artefacts from the scratch dir:
   `signed-tx.hex`, `signed-tx.tx`, `submit.log`.
4. Write `submitted.json`:

   ```json
   {
     "txid": "<txid>",
     "block": "<block-hash>",
     "slot": <integer>,
     "block_time": <unix-seconds>,
     "timestamp": "<ISO-8601 UTC>",
     "submitter": "amaru-treasury-tx <version> (<operator-identifier>)",
     "fee_lovelace": <integer>,
     "valid_contract": true
   }
   ```

   Block + slot from Blockfrost `/txs/{hash}` or
   `cardano-cli query tip` + `cardano-cli transaction txid` cross-check.

5. Rewrite `summary.md` from "awaiting witnesses" to "submitted":
   add the on-chain receipt block, the witness-collection trail,
   and refs to any companion entries (cancelled order, pending
   rebuild, etc.).
6. Update the matching `## Unreleased` bullet in `CHANGELOG.md`
   — edit in place, or split it if the original bullet covered
   multiple pending txs (one submitted, the others still
   pending).

`submitted.json` is the marker that the entry is **done**.
Presence of only `tx.cbor` + `intent.json` without
`submitted.json` means pre-submission. Tools that walk the
`transactions/` tree can rely on that invariant.

## Decode parent txids from a tx body

```bash
python3 - <<PY
import cbor2, io
hex_str = open('transactions/<year>/<scope>/<txid>/tx.cbor').read().strip()
fp = io.BytesIO(bytes.fromhex(hex_str))
fp.read(1)   # array header
body = cbor2.CBORDecoder(fp).decode()
parents = set()
for k in (0, 13, 18):   # inputs, collateral, reference inputs (Conway)
    if k in body:
        for entry in body[k]:
            parents.add(entry[0].hex())
print('\n'.join(sorted(parents)))
PY
```

Typical count for a treasury tx is 2–10 parents (one wallet input,
one treasury input, ~3–4 reference inputs for permissions /
registry / scopes / treasury scripts). Outside that range is a
smell — sanity check before fetching. Also: when feeding the
parent list to a `while read` loop, make sure the file ends with a
newline or the last line is silently skipped.

## Fetching parent CBORs via Blockfrost

```bash
KEY=<config.blockfrostProjectId>
DEST=transactions/<year>/<scope>/<txid>/inputs
mkdir -p "$DEST"
NETWORK_PREFIX=$(case <config.network> in
  mainnet) echo cardano-mainnet ;;
  preview) echo cardano-preview ;;
  preprod) echo cardano-preprod ;;
esac)

while read -r parent; do
  [ -z "$parent" ] && continue
  cbor_hex=$(curl -fsS -H "project_id: $KEY" \
    "https://${NETWORK_PREFIX}.blockfrost.io/api/v0/txs/$parent/cbor" \
    | jq -r .cbor)
  test -n "$cbor_hex" && test "$cbor_hex" != "null" || {
    echo "FAIL $parent" >&2; exit 1; }
  printf '%s' "$cbor_hex" > "$DEST/$parent.cbor"
done < /tmp/parents.txt
```

Never write the project_id to a status log or anywhere git-tracked.

## Why both phases matter

The build-time entry captures the **intent and exact body bytes
the witnesses sign** — invaluable if the tx expires and gets
rebuilt: the pre-submission directory becomes the audit trail
showing "this is the bundle the N owners saw." The post-submission
refresh promotes the entry to "happened on chain" and locks the
directory name to the immutable txid. Together they make
`transactions/` a complete operator record independent of the
scratch dir.

If the tx expires and you rebuild, do **not** delete the
pre-submission entry — the rebuild lives at a sibling slug
(`…-rebuild`); the expired bundle stays archived as historical
context. `tx-diff` between the two proves "only TTL changed."

## Naming after rename

The directory name MUST equal the on-chain txid (lowercase 64-hex
chars). Once `submitted.json` is committed and pushed, the
directory name is **frozen** — references from other entries' or
documents' markdown point at it by name. Renaming after submission
is a workflow incident, not a routine.
