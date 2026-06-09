# Spec — Operate graph-effect preview of an unsigned tx (#345)

## P1 user story
As an operator building an unsigned tx in Operate, I open a **Graph** tab
in the build result and see the tx projected onto the RDF lattice with
**inputs AND outputs resolved** to {scope, role} entities + values
(e.g. "spends contingency treasury UTxO 1.56M ADA → produces
network_compliance treasury +1.56M ADA; recipient = network_compliance
treasury; leftover contingency 307 ADA") — instead of opaque txin refs /
raw datums — so I can validate the semantic graph delta matches intent
BEFORE signing.

## Context (builds on #340 + #346)
- The build already yields the unsigned ConwayTx/CBOR + the resolved
  output {scope,role} + projected datums (#340) over the cardano-ledger-rdf
  vocab (#346). Address→entity resolution + projection engines exist.
- **Inputs are still unresolved** (#340 T340-S2c deferred): a tx input is
  a `txid#ix` outref with no address/value at decode time. Resolving it
  needs a UTxO lookup. The `ApiIndexer` (Api/Indexer.hs) wraps a
  UTxOIndexer with `GetUTxOByAddress`; resolving by **outref** may need a
  different index path — assess.

## Functional requirements
- FR1: Resolve each input outref (`txid#ix`) to its source address →
  {scope, role} + value via the indexed UTxO state (the deferred S2c).
  Surface on `/v1/tx/{txid}` inputs too (no more `scope:null`/`unknown`
  where the indexer has the UTxO).
- FR2: On the unsigned-tx build, produce a structured **graph-effect**
  payload: the tx projected via `Cardano.Tx.Graph.Emit` (#340 engine,
  embedded blueprints) with inputs + outputs resolved to scope/role
  entities (cardano-ledger-rdf vocab) + datums projected. Self-contained
  to the tx (its own resolved projection), inputs resolved from the
  lattice.
- FR3: Operate result panel gains a **Graph** tab rendering the resolved
  effect readably (reuse Format + the resolution surface); thin renderer,
  no client SPARQL/rules.
- FR4: Works on a real contingency disburse + a swap build.

## Non-goals
- Full before→after persisted-lattice diff (triples removed vs added
  across the whole scope lattice) — later enrichment; v1 is the tx's own
  resolved projection with resolved inputs.
- No on-chain/wizard/validator change.

## Success criteria
- Inputs resolve to scope/role+value where indexed; the Graph tab shows
  the resolved spend→produce delta for a contingency disburse + a swap.
- `just ci` + hermetic checks green; live dev smoke on /operate Graph tab.
