# tasks — #475

## Slice A — CLI constants module + report-render pointer
- [X] T001 Add `Amaru.Treasury.Inspector` module (URLs + pointer text) and
      register it in the cabal library.
- [X] T002 Render the "Independent inspection" section in the Markdown report
      and regenerate the three report goldens.
- [X] T003 Add `InspectorSpec` unit test (URLs + pointer content); register in
      the unit test-suite.

## Slice B — witness + coordinate stderr + book-export --help
- [X] T004 Emit the co-signer pointer to stderr from `runWitness` and
      `runCoordinate`, and add a `book-export` help footer naming the
      published book URL.
- [X] T005 Extend the `book-export` and `vault-witness` smokes to assert the
      new pointer/help text.

## Slice C — frontend inspector module + web UI surfaces
- [X] T006 Add `Inspector.purs` (URLs + reusable snippets) and the Books-page
      published-book pointer.
- [X] T007 Add the "Inspect with Cardano Swiss Knife" link to the operate and
      pending signing-facing panels.
- [X] T008 Assert the Inspector URL constants in `Test.Main`.
