# Plan — 357

## Tech stack
- Backend: Haskell, `lib/Amaru/Treasury/Api/*`, reuse `cq-rdf` CLI pattern
  from `History.Sparql` (`entryBodyTurtle`, `metadataEntityTriples`).
- Frontend: PureScript/Halogen, `frontend/src/OperatePage.purs`.

## Slices (each one bisect-safe commit)

### Slice A — backend: built-tx TTL lattice + `ttl` on responses
- New module `lib/Amaru/Treasury/Api/Ttl.hs` (or extend GraphEffect):
  `buildTxLattice :: Maybe TreasuryMetadata -> Text -> IO (Maybe Text)`
  — decode cbor hex, write to temp file, `cq-rdf body`, prepend prefix block
  + `metadataEntityTriples md`. `Nothing` on decode/cq-rdf failure.
  Reuse `History.Sparql` prefix lines + `metadataEntityTriples` (export them
  if not already exported).
- Add `dbrTtl`/`sbrTtl`/`cbrTtl`/`rbrTtl :: Maybe Text` to the four build
  responses + their JSON `ttl` field.
- Wire in `Api/Server.hs` alongside `attach*GraphEffect`: an
  `attach*Ttl` that fills `ttl` from the response cbor hex.
- Proof: golden/unit stay green; a unit test that `buildTxLattice` on a
  fixture cbor yields Turtle containing the expected prefixes (RED→GREEN if a
  harness fits; otherwise the dev smoke is the proof, logged in WIP.md).

### Slice B — frontend: How/What groups + TTL tab
- Add `TabTtl` to `data Tab`; `tabLabel TabTtl = "TTL"`.
- Replace flat `previewTabs` with grouped rendering: **How** =
  [TabIntent, TabCli, TabReport]; **What** = [TabCbor, TabTtl];
  **Analysis** = [TabGraph] (provisional, single tab).
- `previewBody`: add `TabTtl` case → `ttlPreview st` in a `<pre>` + copy
  button (mirror the CBOR tab markup).
- `ttlPreview :: State -> Maybe String` reads `ttl` from the result Json.
- Proof: no frontend test harness → build + dev-deploy + browser smoke,
  logged in WIP.md.
