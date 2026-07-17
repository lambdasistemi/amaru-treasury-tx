# Tasks — book-export verb (issue #472)

## Slice 1 — pure overlay emitter + golden

- [ ] T001 Add `Amaru.Treasury.Book.Export` (`renderOverlayBook`) emitting
  the canonical prefix block and per-scope Owner / Address / CardanoScript
  blocks; expose it in the cabal library.
- [ ] T002 Add checked-in goldens under `test/fixtures/book-export/`
  (full book + `--scope core_development`) and `BookExportGoldenSpec`
  comparing `renderOverlayBook` against them (with `UPDATE_GOLDENS=1`
  regeneration); register the spec in the golden test suite.

## Slice 2 — book-export CLI verb + smoke

- [ ] T003 Add `Amaru.Treasury.Cli.BookExport` (`BookExportOpts`,
  `bookExportOptsP`, `runBookExport`), wire `CmdBookExport` + the
  `book-export` command into `Amaru.Treasury.Cli`, and dispatch it in
  `Main`; expose the module in the cabal library.
- [ ] T004 Add `scripts/smoke/book-export` (offline CLI-surface smoke against
  `test/fixtures/metadata.json`), wire it into the `justfile` `smoke` recipe,
  and register it as an extra-source-file.
