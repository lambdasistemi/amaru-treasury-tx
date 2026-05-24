# Phase 0 — Research

**Feature**: typed `buildSwapTx` + HTTP + `/operate` CBOR & Report
**Branch**: `270-build-swap-typed`
**Date**: 2026-05-24

The spec carries zero `NEEDS CLARIFICATION` markers, but the refactor still needs a handful of small design decisions resolved up-front so the slice commits below are unambiguous. Each one is recorded `Decision / Rationale / Alternatives` per the template.

---

## R1 — Where does `buildSwapTx` live?

- **Decision**: Co-locate `buildSwapTx` with `buildSwapIntent` in `lib/Amaru/Treasury/Wizard/Swap.hs`.
- **Rationale**: Symmetric with `buildSwapIntent`. Both functions share the same `Backend` parameter, the same sysexits mapping, and the same overall position in the pipeline (one wizard, two stages). Putting them side-by-side keeps the typed surface discoverable and makes the imports trivial for the HTTP handler and CLI alike.
- **Alternatives**:
  - *New `Amaru.Treasury.Wizard.Build` module.* Rejected — over-modularisation for a single function; it would duplicate the import overhead at every caller. If the build pipeline grows multiple verticals (disburse, reorganize, withdraw), each gets its own wizard module anyway.
  - *Add directly to `Build.Swap`.* Rejected — the existing `Build.Swap.runSwap` is the legacy shim that we are stepping away from; co-locating the new typed entry there blurs the boundary.

## R2 — How do we enumerate every distinct failure mode in `Build.Swap`?

- **Decision**: Walk `runSwap` + `runSwapAction` top-down, gather every `throwE`, every `exitWith`, every `error`-string, every implicit `MonadFail` path. Each distinct site becomes a `BuildFailure` constructor. Where two sites raise the same conceptual error with the same payload shape, collapse into one constructor.
- **Rationale**: This is the only way to satisfy SC-003 (no unchecked error path reachable from `buildSwapTx`). A constructor count derived from the source guarantees full coverage; deriving it from spec text would let a path slip through.
- **Alternatives**:
  - *Catch-all `BuildFailureOther Text` arm.* Rejected — defeats the typed contract; UIs would have to string-match the freeform field. The whole point of the refactor is to remove the `try @SomeException` catch in `runBuildSwap`.
  - *One constructor per `throwE` call site (no de-duping).* Rejected — readers don't care about call-site identity; they care about failure mode. Two `throwE` arms that both produce "wallet underfunded by N lovelace" are one failure mode and should share a constructor.

## R3 — What does `BuildEvent` look like?

- **Decision**: Mirror `WizardEvent` (#259) one-to-one in structure: one constructor per pipeline step in `Build.Swap` that is interesting for human / log inspection. Concrete starting set: `ResolvingPParams`, `SelectingWalletInputs`, `BuildingSundaeOrder`, `BalancingTx`, `SerialisingTx`, `WritingReport`. The set is open — adding a step later only changes the event sum-type, not control flow.
- **Rationale**: Symmetric with `WizardEvent` keeps the tracer rendering code (already used by `runBuildSwap`'s stderr `Tracer`) consumer-of-both. Operators see one consistent event stream covering the whole wizard → tx-build path.
- **Alternatives**:
  - *Reuse `WizardEvent`.* Rejected — `BuildEvent` corresponds to a different phase of the pipeline; merging them is type-tetris that makes consumers branch on tag-prefix.
  - *One opaque `Text` tracer.* Rejected — defeats round-trip for tests; `BuildEvent` is checked by the FR-004 nullTracer-equivalence property.

## R4 — How does `SwapBuildResponse` encode the four arms?

- **Decision**: Flat record with four mutually-exclusive groupings:
  ```json
  {
    "intentJson":     <Json | null>,
    "cborHex":        <string | null>,
    "report":         <Json | null>,
    "intentFailure":  <{ "tag": "...", "field": "...", "detail": "..." } | null>,
    "buildFailure":   <{ "tag": "...", "step": "...", "detail": "..." } | null>,
    "internalError":  <string | null>
  }
  ```
  Exactly one of `{intentFailure, buildFailure, internalError}` is non-null on a failure; on success all three are null and the data fields are populated. The frontend reads `if buildFailure != null then buildFailure else if intentFailure != null then ...`.
- **Rationale**: Servant + Aeson handle flat records trivially. The frontend `Argonaut` parser doesn't need a tagged-union codec, and the four arms can be rendered by checking field-nullity (matches the rest of the Halogen state machine on `/operate`).
- **Alternatives**:
  - *Sum type with an explicit `tag` discriminator.* Rejected — Aeson's `Generic`-derived sum encoding is heavyweight (the `tag`/`contents` shape) and the frontend has to write a decoder per constructor. Flat record is cheaper for both ends and matches the current `intentFailure` field that already shipped in #263.
  - *Status code based (HTTP 200 only on full success, HTTP 422 on intent failure, HTTP 502 on build failure).* Rejected — the frontend wants to render the typed diagnostic UI even on failure; mixing status codes plus typed bodies doubles the code paths.

## R5 — How does the frontend render the Report tab?

- **Decision**: `JsonTree.render` (default config) on the `report` JSON value, wrapped in the same `<div class="json-tree-wrapper">` container the intent tab uses. The structure-level **Copy report** chip mirrors the **Copy intent.json** chip; the CBOR tab gets its own **Copy CBOR** chip plus the existing `<pre class="cbor-hex">` block.
- **Rationale**: Reuses the library extracted in #263 with zero new surface area. Consistent UX across all three tabs (Intent / CBOR / Report) — same collapse behaviour, same copy ergonomics.
- **Alternatives**:
  - *Bespoke rendering of `Report` fields with custom layout.* Rejected — `Report` JSON is structured enough to be readable as a tree; bespoke rendering would tie the frontend to the Haskell `Report` shape, breaking on every schema bump.
  - *Plain `<pre>` block with stringified report.* Rejected — strictly worse than the JSON tree; no cardanoscan links, no copy buttons, harder to scan.

## R6 — Where do the new tests live?

- **Decision**: Two new spec files:
  - `test/unit/Amaru/Treasury/Wizard/BuildSwapSpec.hs` — HTTP-shaped per-variant harness. Feeds deliberately malformed inputs to `buildSwapTx`; asserts every `BuildFailure` constructor is matched at least once (QuickCheck enumeration over the constructor list, derived via `Data.Data` or a manual list).
  - `test/unit/Amaru/Treasury/Wizard/BuildSwapGoldenSpec.hs` — extends the existing swap golden corpus to pin the CBOR + report.json bytes produced by `buildSwapTx` against the v0.2.15.0 fixtures.
  Plus `test/unit/Amaru/Treasury/Api/ServerSpec.hs` grows a `SwapBuildResponse` round-trip case.
- **Rationale**: Co-located with `Wizard.Swap` so the spec module name mirrors the source module. The split between the per-variant harness and the golden corpus mirrors the #259 layout, which kept those two concerns clean.
- **Alternatives**:
  - *One mega-spec that does both.* Rejected — the golden corpus is byte-pinning, the harness is variant-coverage; failure modes are different and the test output is harder to triage.

## R7 — How do we avoid a backwards-incompatible HTTP schema change for existing consumers?

- **Decision**: All new fields on `SwapBuildResponse` are `Maybe` (i.e. nullable). Existing consumers that only read `intentJson` keep working unchanged; new consumers opt-in to `cborHex` + `report`.
- **Rationale**: Aeson's `Generic` encoding writes `null` for `Nothing`; Argonaut on the frontend already tolerates nulls in the existing intent-failure path. No version bump needed for the response schema.
- **Alternatives**:
  - *New `/v2/build/swap` endpoint.* Rejected — premature versioning; the API has one in-house frontend and zero external consumers, so the additive change carries no risk.

---

## Open questions

None. Every NEEDS CLARIFICATION in the spec was already resolved by the spec author (the spec was self-clarified per the user's earlier "spec is technical because the user IS the Haskell engineer" framing). Phase 1 can proceed.
