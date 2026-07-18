# Plan — publish canonical treasury books (issue #474)

## Tech context

- Publish surface: existing `deploy-docs.yml` ("Build and deploy
  documentation") copies `docs/**` into the MkDocs `site/` and deploys to
  GitHub Pages on push to `main`. Static assets under `docs/assets/`
  (e.g. `intent-schema.json`) are already served at
  `https://lambdasistemi.github.io/amaru-treasury-tx/assets/…` with
  `access-control-allow-origin: *`. The book asset rides the same path.
- Generator: the `book-export` verb (#472). Output is deterministic
  Turtle — a pure function of the metadata bytes.
- Drift check: mirror the existing `schema` check in `nix/checks.nix`
  (run the generator, `diff -u` against the committed asset).

## Slices (one bisect-safe commit each)

- **S1 — vendor canonical journal + generated book** (`feat`).
  `journal/2026/metadata.json` (upstream verbatim, typo preserved),
  `journal/README.md` (provenance), `docs/assets/amaru-treasury-book.ttl`
  (generated). Adds published artifacts; no behavior change to existing
  verbs.
- **S2 — book drift check in CI** (`ci`). Add a `book` check to
  `nix/checks.nix` that regenerates the book from the vendored metadata
  and `diff -u`s it against the committed asset (fails closed); wire
  `.#checks.x86_64-linux.book` into `ci.yml`'s build-gate; extend
  `gate.sh` to invoke it.
- **S3 — document the book URL** (`docs`). README section + a `docs/book.md`
  page (MkDocs nav) naming the URL and its purpose.

## Verification

- Local: build the exe, regenerate the book, `diff` against the committed
  asset (byte-identical); mutate the asset and confirm the `book` check
  fails closed.
- Live proof: open a draft PR; the `pull_request` docs deploy publishes a
  preview containing the book; drive the csk Library "Book URL" import in a
  real browser (Playwright) and record the parts count. The final
  `github.io` URL scheme + CORS is proven by the already-deployed
  `intent-schema.json` headers and is same-origin with the csk Library.
