# Plan — book-export verb (issue #472)

## Tech stack

Haskell (GHC 9.12.3, haskell.nix), `optparse-applicative`, `text`,
`containers`, `aeson` (metadata already parsed by
`Amaru.Treasury.Metadata`). Pure emitter + thin IO runner, mirroring the
`report-render` subcommand structure. Golden via Hspec (`hspec-discover`).

## Modules

- `Amaru.Treasury.Book.Export` (new, pure) — `renderOverlayBook :: Maybe
  ScopeId -> TreasuryMetadata -> Text`. Builds the canonical prefix block
  and the per-scope Owner / Address / CardanoScript blocks. No IO.
- `Amaru.Treasury.Cli.BookExport` (new) — `BookExportOpts`,
  `bookExportOptsP`, `runBookExport`. Reads metadata, renders, writes to
  `--out` or stdout. Mirrors `Amaru.Treasury.Cli.ReportRender` error/exit
  handling.
- `Amaru.Treasury.Cli` — add `CmdBookExport` + the `book-export` command.
- `app/amaru-treasury-tx/Main.hs` — dispatch `CmdBookExport` (offline, no
  socket, like `report-render`).
- `scripts/smoke/book-export` + `justfile` `smoke` list — offline CLI-surface
  smoke asserting the verb emits the expected classes against the fixture.

## Reuse notes

The `Report.Identity` AddressBook machinery is report+intent driven, so it
does not fit a metadata-only export; the label vocabulary is mirrored instead
(as `History.Sparql.metadataEntityTriples` already does). Fixture reused:
`test/fixtures/metadata.json` (5 scopes, 4 owners, 15 script hashes).

## Slices (one bisect-safe commit each)

- **S1** Pure emitter + golden. `Book.Export` module, `BookExportGoldenSpec`
  (full book + `--scope core_development`), checked-in goldens under
  `test/fixtures/book-export/`. Cabal: expose module, register spec.
  Proof: `just golden`.
- **S2** CLI verb + smoke. `Cli.BookExport`, `Cli` command, `Main` dispatch,
  `scripts/smoke/book-export`, `justfile`. Cabal: expose module, register
  smoke as extra-source-file. Proof: `just build`, `just smoke`, run the verb
  against the fixture and diff against the S1 golden.

## Verification

`./gate.sh` (build + unit + golden + format-check + hlint + smoke), plus a
manual `book-export --metadata test/fixtures/metadata.json` run diffed
against the checked-in golden.
