# plan — #32

## Strategy

Swap the one call site in `translateSwap` to
`parseRewardAccountForNetwork (tiNetwork ti)`, exactly as
`translateDisburse` already does, and delete the now caller-less
`parseRewardAccount` (definition in `IntentJSON/Common.hs`, export
lists in `IntentJSON/Common.hs` and `IntentJSON.hs`) in the same
diff (leanness swap rule).

## Proof

A unit test in the existing unit suite executes the swap
translation on a non-mainnet swap intent and asserts the permissions
reward account's network; it fails on `main` (INV-1). A mainnet
counterpart and an unknown-network rejection cover INV-2/INV-4 at
the unit level; goldens cover INV-2 byte-for-byte.

## Slices

One bisect-safe slice, S1: RED test + fix + deletion, squashed to a
single `fix:` commit.

## Gates

`just ci` (build, unit, golden, lint, format, schema, smoke) per
`justfile`/CI; see the frozen slice gate in the runtime root.
