# plan — #475

## Tech

- CLI: Haskell (GHC 9.12.3). New pure module `Amaru.Treasury.Inspector`
  centralising the URLs + co-signer pointer text. Consumed by the Markdown
  report renderer, the `witness` runner (stderr), the `coordinate` runner
  (stderr), and the `book-export` subcommand help footer.
- Frontend: PureScript + Halogen. New module `Inspector` centralising the
  URLs + reusable HTML snippets. Consumed by BooksPage, OperatePage,
  PendingPage.

## Slices (one bisect-safe commit each)

### Slice A — CLI constants module + report-render pointer
- Add `lib/Amaru/Treasury/Inspector.hs`: `inspectorUrl`, `publishedBookUrl`,
  `cskLibraryUrl`, `coSignerPointerLines` (plain, for stderr), plus the two
  invitation strings the report reuses.
- `Report/Render.hs`: append an "Independent inspection" heading2 + two
  bullets built from the constants.
- Regenerate the three report goldens (`UPDATE_GOLDENS=1 just golden`).
- Add `test/unit/Amaru/Treasury/InspectorSpec.hs`; register the library
  module + the spec in `amaru-treasury-tx.cabal`.
- Gate: unit + golden + smoke (report-render swap round-trip).

### Slice B — witness + coordinate stderr + book-export --help
- `Cli/Witness.hs` `runWitness`: emit `coSignerPointerLines` to stderr.
- `Cli/Coordinate.hs` `runCoordinate`: emit `coSignerPointerLines` to stderr.
- `Cli.hs`: add a `footer` on the `book-export` command naming the published
  book URL.
- Extend `scripts/smoke/book-export` (assert --help names the URL) and
  `scripts/smoke/vault-witness` (assert witness stderr shows the pointer).
- Gate: smoke green.

### Slice C — frontend inspector module + web UI surfaces
- Add `frontend/src/Inspector.purs`: `inspectorUrl`, `publishedBookUrl`,
  `cskLibraryUrl`, `inspectLink`, `publishedBookPointer`.
- BooksPage: published-book pointer panel (visible URL + Copy + CSK Library
  link).
- OperatePage: inspect link inside the save-to-pending (co-signing) panel.
- PendingPage: inspect link + book pointer inside the Distribute panel.
- Test.Main: assert the three URL constants.
- Gate: `nix build .#frontend` + `spago test`.

## Risks

- Golden churn: three report goldens change. Mitigated by the deterministic
  renderer + UPDATE_GOLDENS.
- Existing playwright specs: additive-only DOM changes; no selector removed.
