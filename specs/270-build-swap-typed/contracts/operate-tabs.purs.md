# Contract — `/operate` preview tabs (frontend)

**Module**: `frontend/src/OperatePage.purs`
**Stability**: UI contract; class names + DOM selectors are the load-bearing surface for the `[data-field]` highlight mechanism.

## Tab population

Today (#263 baseline):

| Tab     | Visible | Rendered from                      |
|---------|---------|------------------------------------|
| Intent  | yes     | `JsonView.renderWith` over the wrapped `{ details: <intent> }` |
| CLI     | yes     | `<pre class="cli-block">` with `cliCommand` |
| CBOR    | disabled | "ships in PR B" placeholder        |
| Report  | disabled | "ships in PR B" placeholder        |

After this slice:

| Tab     | Visible                                          | Rendered from                                                                                                                                                          |
|---------|--------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Intent  | yes (unchanged)                                  | unchanged                                                                                                                                                              |
| CLI     | yes (unchanged)                                  | unchanged                                                                                                                                                              |
| CBOR    | enabled iff `response.cborHex != null`           | `copyBlockButton "Copy CBOR" cborHex` above a `<pre class="cbor-hex">` containing the hex string                                                                       |
| Report  | enabled iff `response.report != null`            | `copyBlockButton "Copy report" (stringify report)` above `JsonView.renderWith (defaultConfig { initiallyOpen = true })` over the wrapped `{ details: <report> }`        |

When a tab's source field is `null`, the tab MAY remain visible but the body shows a one-line "not built yet" caption (consistent with the existing disabled state).

## Status banner

Today: `report-status` chip with `data-ok` attribute = build state ("ok" / "fail").

After this slice: the chip's text content reads:

- Success → `Built` (data-ok="ok")
- Intent failure → `intent: <FailureTag.tag>` (data-ok="fail")
- Build failure → `build: <FailureTag.tag>` (data-ok="fail")
- Internal failure → `error` (data-ok="fail")

## Field highlighting (FR-012)

When `intentFailure.field` or `buildFailure.field` is non-null, the corresponding form input gets a `data-error="true"` attribute. CSS in `style-build.css` already styles `.field__input[data-error="true"]` with the error-container colour (it's the existing affordance from #263).

Mapping is the field-reference table in [data-model.md § Field reference for the frontend](../data-model.md#field-reference-for-the-frontend-r4--fr-012). The frontend reads the `field` value verbatim and looks up an input element with `[data-field="<value>"]`.

## State machine (Halogen)

State additions on `State`:

```purescript
type State =
  { ...                            -- existing fields
  , cborHex          :: Maybe String
  , report           :: Maybe Json
  , buildFailure     :: Maybe FailureTag
  , buildErrorField  :: Maybe String  -- derived from intentFailure || buildFailure
  }
```

Action handler `HandleBuildResponse` parses the `SwapBuildResponse` JSON, updates the four fields, sets `buildErrorField` from the appropriate failure variant, and re-renders.
