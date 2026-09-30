# transactions/

Operator-local historical log of every transaction produced by the
wizards (`swap-wizard`, `withdraw-wizard`, `disburse-wizard`,
`swap-cancel`) and `tx-build` in this repository.

Each entry stores the wizard intent, the unsigned Conway transaction
body, the submission receipt, and a human-readable summary on disk.
The directory mirrors the per-scope split used by
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026),
but archives machine artifacts alongside the narrative because this
repo *produces* them.

This layout is the storage substrate that #163 will later hash-commit
on-chain. The on-chain hash commitment is intentionally **not** part
of this layout yet; see [Cross-references](#cross-references) below.

## Layout

```
transactions/
  README.md
  <year>/
    <scope>/
      <txid-or-slug>/
        intent.json
        tx.cbor
        submitted.json
        summary.md
```

Years are calendar years (UTC). Scopes mirror the
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
split. The per-transaction directory is named for the on-chain txid
once known; before submission operators use a short kebab-case slug.

## Scopes (2026)

The five scopes track the budget split declared by the on-chain
[treasury contracts setup](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026).
Each scope has its own on-chain treasury account.

- `core_development/` — core protocol and node development work.
- `ops_and_use_cases/` — operations and concrete use-case delivery.
- `network_compliance/` — network-level compliance work (includes
  funding the per-scope treasuries from the protocol treasury).
- `middleware/` — middleware and tooling layers between core and
  applications.
- `contingency/` — unplanned spend approved against the contingency
  reserve.

If the scope set changes in a future year, add a new
`transactions/<year>/` tree with the new scopes; do not retro-rename
existing directories.

## Per-transaction artifacts

Each `<txid-or-slug>/` directory contains four files:

- `intent.json` — wizard output. The structured intent that
  `tx-build` consumes to produce the unsigned body.
- `tx.cbor` — the unsigned Conway transaction body emitted by
  `tx-build` (raw CBOR bytes).
- `submitted.json` — submission receipt:
  `{ txid, slot, timestamp, submitter }`. Written once the tx is
  on-chain.
- `summary.md` — human-readable description in the style of the
  upstream journal: what the tx does, who proposed it, which
  approvals it required, links to relevant issues or PRs.

Historical entries backfilled from on-chain data may have only a
subset of these files (typically `tx.cbor`, `submitted.json`, and
`summary.md` — `intent.json` is unrecoverable once lost). When that
happens `summary.md` should call out which files are missing and why.

## Naming convention

- Before submission: a short kebab-case slug prefixed with the
  UTC date the intent was produced, e.g.
  `2026-05-20-network-compliance-fund-usdm/`.
- After submission: operators MAY rename the directory to the
  hex-encoded `txid`. Renaming is optional but recommended once
  the tx is final; the slug remains valid if kept.
- Either way the directory name is stable: do not rename a
  directory once `submitted.json` is committed and referenced
  elsewhere.

## Add-an-entry checklist

For operators producing a new transaction:

- [ ] Pick the correct `<year>/<scope>/` directory.
- [ ] Create `<year>/<scope>/<slug>/` using the slug convention
  above.
- [ ] Drop the wizard's `intent.json` into the new directory.
- [ ] Run `tx-build` and save the unsigned body as `tx.cbor`.
- [ ] Write `summary.md` describing the intent, approvals, and
  any relevant links.
- [ ] After submission, write `submitted.json` with the txid,
  slot, timestamp, and submitter identifier.
- [ ] Optionally rename the directory to the txid.
- [ ] Commit the four files together so the historical log stays
  bisect-friendly.

## Cross-references

- #163 will introduce a canonicalisation rule and an on-chain
  hash commitment over this directory. That work is intentionally
  out of scope here: this ticket only establishes the on-disk
  substrate the future register will anchor.
