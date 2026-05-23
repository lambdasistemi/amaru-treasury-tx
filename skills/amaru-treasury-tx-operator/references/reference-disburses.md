# Reference-set disburses (Principle VIII v2 / v3)

Every operator-facing disbursement under Principle VIII v2 carries an
on-chain `rationale.references` array — a structured list of
`(label, type, uri)` IPFS pointers that bind the tx to its off-chain
audit chain. The canonical wizard surface is the trio of repeatable
flags `--reference-uri / --reference-type / --reference-label`; the
operator never hand-rolls the rationale aux-data.

## Source of truth: per-cycle manifest

Each operational cycle ships one manifest under
`transactions/<year>/<scope>/<cycle>-references.json` enumerating every
disbursement, its payee / beneficiary IDs, USDM amount, and the full
reference set. Example: `transactions/2026/network_compliance/may-references.json`.

Schema (`amaru-treasury-may-references-v2`):

```json
{
  "schema": "amaru-treasury-may-references-v2",
  "scope": "network_compliance",
  "month": "2026-05",
  "constitution_principle": "VIII",
  "constitution_version": "<version-at-manifest-time>",
  "disbursements": [
    {
      "id": "<cycle>-<vendor>",
      "amount_usdm": <int>,
      "payee_id": "<vendor-id>",
      "beneficiary_id": "<vendor-id>",
      "references": [
        { "kind": "payee_contract",          "vendor_id": "...", "uri": "ipfs://...", "type": "Other", "label": "..." },
        { "kind": "payee_address_proof",     "vendor_id": "...", "uri": "ipfs://...", "type": "Other", "label": "..." },
        { "kind": "beneficiary_contract",    "vendor_id": "...", "uri": "ipfs://...", "type": "Other", "label": "..." },
        { "kind": "beneficiary_invoice",     "vendor_id": "...", "uri": "ipfs://...", "type": "Other", "label": "..." },
        { "kind": "beneficiary_cycle_review","vendor_id": "...", "uri": "ipfs://...", "type": "Other", "label": "..." }
      ]
    }
  ]
}
```

Manifest `constitution_version` captures the constitution version
**at manifest creation time**. Do not bump it just because a later
amendment has shipped — the version is part of the historical record.

## Per-disbursement build script

Each disbursement gets one script under
`scripts/build-<cycle>-<vendor>-disburse.sh`. The script:

1. Reads the manifest entry by `--disbursement-id` (default-baked).
2. Validates the schema (payee / beneficiary IDs, amount, expected reference kinds).
3. Reads the payee on-chain address from `vendors.yaml` (rejects `<TBD…>` placeholders).
4. Applies any carve-outs at the script layer (see NDA below).
5. Templates the rationale text fields (description / justification / destinationLabel / label) with defaults that fit the **64-byte UTF-8 per-text metadatum cap** — the wizard does NOT auto-chunk these (only URIs and reference labels).
6. Assembles the wizard argv. Prints it to stdout for runbook capture; runs it under `--exec`.

The CC build script `scripts/build-may-cc-disburse.sh` is the canonical
template — copy it for each new disbursement (CC, Antithesis, etc.)
rather than parameterising one mega-script. Per-disbursement scripts are
the published artefact future auditors run to reproduce; one script per
disbursement keeps the diff between cycles small and reviewable.

## NDA carve-out (Principle VIII v3 A)

When the beneficiary's engagement contract is under NDA, the on-chain
rationale **omits** the `beneficiary_contract` reference and the
`justification` text explicitly acknowledges the omission. The manifest
should still list the contract URI (so the existence of the engagement
is recorded), and the build script filters that reference out before
the wizard call. Example default (Antithesis):

```text
justification = "Beneficiary contract omitted: Antithesis NDA (P-VIII v3 A)."
```

The build script's `--keep-beneficiary-contract` flag opts back into
the full reference set when the carve-out doesn't apply.

Minimum evidence-set sizes per cycle type × NDA matrix:

| Beneficiary contract type | All refs published | With NDA carve-out |
| --- | --- | --- |
| Periodic (with cycle review) | 5 | 4 |
| Periodic (no cycle review)   | 4 | 3 |
| Yearly (collapse rule)       | 3 | 3 |

The wizard does NOT enforce these counts — `gate.sh` (and operator
discipline) does.

## NON-NEGOTIABLE: amount-vs-invoice cross-check

Before signing any disburse, the operator MUST manually download the
pinned invoice CID and verify the disbursed amount matches the invoice
total. Reject any unsigned tx whose amount does not match the invoice.

```bash
CID="$(jq -r '.rationale.references[]
              | select(.label | test("Invoice"))
              | .uri | sub("^ipfs://"; "")' "$RUN/intent.json")"
curl -fsSL --max-time 60 -o /tmp/invoice.pdf "https://ipfs.io/ipfs/$CID"
nix --quiet shell nixpkgs#poppler-utils -c \
    pdftotext -layout /tmp/invoice.pdf - \
  | grep -E "(AMOUNT DUE|TOTAL|amount)"
```

Read the result and confirm against `intent.disburse.amount` (scaled
by `1e-6` for USDM). This rule was added to the constitution (v0.5.1,
2026-05-22) after a 6 000-USDM mis-build caused by skipping the check.

## Rebuild via the wizard — do NOT surgical-edit

When a published / in-flight disburse needs a correction (wrong invoice
CID, wrong amount, wrong rationale text), **always rebuild via the
wizard**. Never patch `intent.json`, `tx.cbor.hex`, or any downstream
artefact in place.

Why: the published archive is the trail `command → wizard → build.log →
intent.json → tx-build → tx.cbor + envelope`. A surgical edit to
`intent.json` leaves `build.log` referring to inputs that no longer
produce that intent — the published artefact set stops being internally
reproducible.

Procedure:

1. Fix the manifest (or per-vendor script defaults) — that's the source
   of truth.
2. Move any already-collected witness aside as
   `witness-<scope>.envelope.json.stale-<reason>` so it can't be
   mistakenly attached to the new tx body.
3. Re-run the build script with `--exec`. The wizard re-queries the
   chain (UTxOs may shift), refreshes the validity slot, and writes a
   consistent `intent.json` + `build.log`.
4. Re-run `tx-build` → `envelope-tx`. The new `report.json` carries
   the new txId at `result.report.identity.txId`.
5. Re-collect every witness from scratch — the new tx body hash
   invalidates the prior signatures.

Stale-witness preservation is mandatory: the old `.stale-<reason>`
file is evidence of which-CID-was-leaky-when, useful for the
post-mortem that the constitution amendment relied on.

## Where to find the new txId

```bash
jq -r '.result.report.identity.txId' "$RUN/report.json"
```

Not at the top level of `report.json`. Not in `tx.envelope.json`
either — the envelope only carries `type / description / cborHex`.
Computing from CBOR would work but is unnecessary when `report.json`
already has it.

## Wizard binary version sensitivity

The `--reference-uri / --reference-type / --reference-label` flags
shipped in **v0.2.13.0** (PR #197). System-PATH binaries that lag
behind will reject the flags with `Invalid option`. When the host PATH
has a stale binary, pin a known-good one via the worktree's flake:

```bash
BIN=$(nix build --no-link --print-out-paths .#default)/bin/amaru-treasury-tx
scripts/build-<cycle>-<vendor>-disburse.sh --binary "$BIN" ...
```

Always log the `--version` of the binary that produced the artefacts
into `build.log` so future auditors can reproduce against the same
surface.
