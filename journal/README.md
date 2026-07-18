# Vendored treasury journal metadata

`2026/metadata.json` is a **verbatim copy** of the canonical Amaru
treasury journal metadata published upstream. It is the source
`book-export` renders into the published overlay book
(`docs/assets/amaru-treasury-book.ttl`).

## Provenance

- Upstream repo: <https://github.com/pragma-org/amaru-treasury>
- Path: `journal/2026/metadata.json`
- Pinned commit: `15817e6bcd6da7121f93022508572784af94a270` (`main`)
- Last upstream change to this file:
  `99600d8cedf0e3c4894fe7f45d5e8abad2289d76` (2026-05-01)
- sha256: `921f0f8dc2c219826ffb02eea2ec37d1fda70623dab35e9f30537b2ada919145`

Re-fetch / verify:

```bash
git -C <amaru-treasury clone> show \
  15817e6bcd6da7121f93022508572784af94a270:journal/2026/metadata.json \
  | sha256sum
# 921f0f8dc2c219826ffb02eea2ec37d1fda70623dab35e9f30537b2ada919145
```

This is **not** the repo test fixture. `test/fixtures/metadata.json` is a
different, corrected copy used only by the golden tests; it is not the
real journal. The book is generated from *this* vendored file so the
published artifact tracks the canonical upstream journal.

## Known upstream typo — preserved faithfully

The `contingency` scope's `registry_script.hash` in the upstream journal
is

```
7d275cf8c09fd91e73879993ef13cb73915196478d5e3777992f988    (27.5 bytes)
```

one hex nibble short of the on-chain script hash

```
7d275cf8c09fd91e73879993ef13cb73915196478d5e3777992f9888   (28 bytes)
```

This typo is reproduced **verbatim** here and in the generated book: the
resolution book is a faithful export of the journal as published and does
not silently correct source data. Operators building contingency-scope
transactions supply the corrected value out of band (see the
`amaru-treasury-tx` operator skill); the book is not an authority on
on-chain hashes.
