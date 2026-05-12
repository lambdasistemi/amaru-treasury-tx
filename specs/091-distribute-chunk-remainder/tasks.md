# Tasks — Distribute swap-order remainder

Spec: [spec.md](spec.md) · Plan: [plan.md](plan.md) · Issue: [#91](https://github.com/lambdasistemi/amaru-treasury-tx/issues/91).

## S1 — `chunkLovelaces` + matching `mkChunks` + `chunkCountFor` *(one reviewed commit)*

| Task | Type | Output |
|---|---|---|
| T1.1 | RED | `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: add a `describe "chunkLovelaces"` block with 4 unit cases (dust-fold, clean-divide, tiny amount, chunk-usdm shape) and 1 QuickCheck `prop_chunkSumInvariant`. Use the public `chunkCountFor` plus a new exported `chunkLovelaces` helper. |
| T1.2 | GREEN | `lib/Amaru/Treasury/Tx/SwapWizard.hs`: add `chunkLovelaces :: Integer -> Integer -> [Integer]`; rewrite `chunkCountFor` as `toInteger . length . uncurry chunkLovelaces` (or equivalent). Export `chunkLovelaces`. |
| T1.3 | GREEN | `lib/Amaru/Treasury/IntentJSON.hs`: rewrite `mkChunks` to map each `chunkLovelaces`-emitted value to a `SwapOrderOut`. The USDM scaling helper (`usdm n`) stays per-chunk. |
| T1.4 | docs | `lib/Amaru/Treasury/Tx/SwapWizard.hs` haddock + `lib/Amaru/Treasury/IntentJSON.hs` haddock: describe the distribute rule and the invariant. |
| T1.5 | gate | Confirm `nix develop -c just ci` is green (build, unit, golden, red, smoke, fmt, hlint). Existing fixture is unchanged. |

**Reviewed commit message**: `fix(091): distribute swap-order remainder; no dust outputs`.

**Folding into one commit**: T1.1–T1.5 land in a single `git commit`. RED tests + GREEN impl in the same commit; the dust-fold case fails compilation/test until the implementation lands.

## S2 — Live re-verification *(no commit; PR description evidence)*

Manual re-run against mainnet:

| Task | Type | Output |
|---|---|---|
| T2.1 | smoke | `swap-wizard` against mainnet socket emits 33 swap-orders (not 34). Treasury leftover recovers 3,280,000 lovelace vs. today. |
| T2.2 | smoke | `tx-build` of the new intent passes script evaluation, fee within a few hundred lovelace of bash's 1,042,614. |
| T2.3 | smoke | `jq '.outputs | group_by(.amount.lovelace) | …'` of the structured view confirms the new chunk distribution (5 × `c+1` + 28 × `c` + 1 wallet change + 1 treasury leftover). |

Result attached to [PR #91-PR] description as a `jq` block (see plan §"Live re-verification").

## Folding & bisect-safety summary

S1 is one bisect-safe commit. The fixture-rewriting RED step + GREEN impl + Haddock land together. S2 is operator-side smoke evidence; no new commits.
