# Amaru treasury 2026 book

An RDF overlay Turtle asset (`overlay.ttl`) covering every submitted 2026
treasury transaction archived under `transactions/2026/`: scope, action,
description, justification, destination label, operator wallet,
beneficiary / swap-order address, amount, required signers, and the
on-chain receipt (block, slot, fee, submission time).

This is a "book" in the [cardano-ledger-inspector][cli] sense (see its
`specs/104-book-resolution` and `specs/106-local-book-store`): a Turtle
asset that resolves opaque decoded-transaction nodes (addresses, signer
key hashes) to familiar labels when merged into the inspector's RDF
graph, and that a SHACL shapes book can validate against.

It complements, but does not replace, the static deployment registry
already vendored into cardano-ledger-inspector at
`docs/inspector/protocols/amaru-treasury/` (sourced from the upstream
`pragma-org/amaru-treasury` journal — scope-level treasury/permissions/
registry script hashes and owner keys). This book adds what only this
repo's own archive knows: the operator wallet(s), beneficiaries, and
per-transaction rationale text actually used across submitted 2026
transactions.

## Regenerating

```bash
book/generate.sh
```

Re-run after archiving a new transaction under `transactions/2026/`.
The script reads each scope/txid directory's `submitted.json` (schema
varies across archive vintages; both are handled) plus `intent.json`
when present, and falls back to parsing `summary.md` for the small
number of pre-`intent.json` archives (swap-cancel/swap-rerate).

## Using it in cardano-ledger-inspector

Open the hosted inspector's `/library` route, "Add a book" → From URL,
and point it at this file's raw GitHub URL (or paste the file
contents). Select it alongside a decoded transaction to resolve wallet
and beneficiary addresses and signer key hashes to their 2026-book
labels.

## Namespace

```
@prefix book: <https://lambdasistemi.github.io/amaru-treasury-tx/book#> .
```

`book:Transaction`, `book:Address`, and `book:Signer` are this book's
only classes; address/key nodes are minted as `urn:cardano:id:address:<bech32>`
and `urn:cardano:id:key:<hash>`, the same scheme the vendored Amaru
overlay book uses, so the two books' owner-key nodes merge when both are
selected together.

[cli]: https://github.com/lambdasistemi/cardano-ledger-inspector
