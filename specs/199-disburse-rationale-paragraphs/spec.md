# #199 — Disburse rationale accepts multi-paragraph text

## Story

As a treasury operator writing a disburse `intent.json`, I give the
rationale `description` / `justification` either as one string or as
an array of paragraphs, and every paragraph lands, in order, in the
CIP-1694 rationale metadatum of the built transaction.

## Current behaviour

The unified intent parser already accepts string-or-array through
`RationaleText` (`IntentJSON.hs`, commit 9a527780), and the unified
schema (`rationaleSchema`) already advertises it. The disburse path
parses its own `DisburseRationaleJSON` with scalar `Text` fields and
wraps them as `[text]`, so an array (e.g. the d6c14625 mainnet shape
in `test/fixtures/disburse/d6c14625-references/intent.json`) is
rejected by the disburse JSON layer.

## Requirements

- REQ-1 Disburse `rationale.description` and `rationale.justification`
  accept a JSON string or a JSON array of strings.
- REQ-2 The accepted shape is the shared `RationaleText` from
  `Amaru.Treasury.IntentJSON`; no second string-or-array
  implementation exists in the disburse path.
- REQ-3 Every paragraph reaches `RationaleBody.rbDescription` /
  `rbJustification` in input order, unjoined.
- REQ-4 Any other JSON type for those fields is rejected at parse time.

## Invariants

- INV-1 (multi-paragraph reaches the body) A disburse intent whose
  description/justification are arrays, parsed through the disburse
  JSON layer (`FromJSON`), yields a `RationaleBody` whose description
  and justification lists equal the input arrays element-wise.
  Fails on `origin/main` (parse error or collapsed list).
- INV-2 (scalar compatibility) A scalar-string intent yields the same
  single-element lists as today; all existing intents parse unchanged.
- INV-3 (goldens byte-identical) Every golden test passes with no
  golden file modified.
- INV-4 (shared implementation) The disburse rationale fields have
  type `RationaleText`; no new string-or-array parser is introduced.
- INV-5 (round-trip) Disburse `ToJSON` re-emits the shape it parsed
  (string stays string, array stays array).
- INV-6 (CI) `nix develop --quiet -c just ci` green; the `smoke`,
  `schema` and `lint` CI jobs green on the pushed head.

## Non-goals

- New repeatable paragraph flags on the wizard (out of scope unless
  trivially additive and default-preserving; not requested here).
- Changing the CIP-1694 metadatum shape.
- The non-disburse actions (already handled by 9a527780).
