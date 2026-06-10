# Plan — 358

## Slices (each one bisect-safe commit)

### Slice A — backend: lattice input-values + 3 SPARQL proofs + runner
- Extend the built-tx lattice: a function that, given the resolved input
  UTxOs (reuse `snapshotUtxosByTxIn` as GraphEffect does), emits
  `cardano:`-vocab value triples for each spent input, appended to the
  `buildTxLattice` Turtle. Keep the #357 `buildTxLattice` working; add an
  enriched variant (or an optional resolved-UTxO arg).
- Add 3 `.rq` files under a new dir (e.g.
  `lib/Amaru/Treasury/Api/proofs/` or reuse the History queries dir),
  embedded via `embedFile`, adapting the History vocab.
- A runner mirroring `runNamedHistoryQuery`: build the enriched lattice,
  `runArq` each query, parse TSV → {name, columns, rows}.
- Add a `Maybe [ProofResult]` field to the build responses (ProofResult =
  {name, columns, rows}); wire `attach*Proofs` in Server.hs next to
  `attach*Ttl`. Best-effort (Nothing/empty on cq-rdf/arq failure).
- Proof: unit test that the runner over a fixture cbor returns the 3 named
  proofs with non-empty columns; conservation balances on a known fixture.

### Slice B — frontend: Analysis group renders spend→produce + 3 proofs
- Replace the single provisional Analysis tab body with: the existing
  `graphEffectView` (spend→produce) followed by a table per proof
  (columns header + rows). Reuse existing table/section markup.
- A `proofsPreview :: State -> Array {name,columns,rows}` reading the new
  response field (mirror `ttlPreview`/`cborHexPreview` prefix pattern).
- Proof: `nix build .#frontend` + dev browser smoke.
