# spec — #33 Replace `fromJust . hashFromBytes` with typed errors

## Problem

`mkHash28` / `mkHash32` are `fromJust . hashFromBytes`, exported from
`Amaru.Treasury.IntentJSON.Common` and duplicated privately in
`Amaru.Treasury.Tx.DisburseIntentJSON`. Both names are polymorphic in
the hash algorithm, so the digit in the name does not bind the byte
length: a byte string whose length differs from the algorithm's digest
size crashes the process with `fromJust: Nothing` instead of producing
a parse error. Every current parser call site pre-checks the length
with `decodeHexBytes <n>`, so the crash is latent in the helper, not
reachable through today's parsers; one call site
(`parseGovernanceAnchor`) already pairs a 32-byte check with
`mkHash28`, which works only because the name is not the contract.

## Requirements

- REQ-1 — Byte string → hash conversion in `lib/` is total: a
  wrong-length input yields `Left` whose message names the expected
  and the actual byte length; a correct-length input yields the hash
  whose bytes equal the input.
- REQ-2 — Every production call site threads that `Left` through its
  existing parser error channel (`Either String`, `ResolverError`,
  `wrapParse`, …). No call site discards it with a partial function.
- REQ-3 — The private duplicates in
  `Amaru.Treasury.Tx.DisburseIntentJSON` are deleted; that module uses
  the shared helper from `Amaru.Treasury.IntentJSON.Common`.
- REQ-4 — No `fromJust . hashFromBytes` (or equivalent partial
  composition over `hashFromBytes`) remains in `lib/`. The constant
  devnet helper in `Amaru.Treasury.Devnet.GovernanceWithdrawalInit`
  is made total, or kept partial only if named as a harness-only
  constant.
- REQ-5 — Intent parsing of valid inputs is unchanged: every golden is
  byte-identical, the intent/report/inspect schemas are unchanged, and
  wrong-length hash fields in an intent still yield a parse `Left`.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | the shared helper returns `Left` naming expected and actual length for every wrong length, for both a 28-byte and a 32-byte algorithm | any wrong length crashes, or yields `Right` |
| INV-2 | the shared helper round-trips every correct-length input (`hashToBytes` of the result equals the input) | a correct-length input yields `Left` or different bytes |
| INV-3 | an intent whose hash field (txIn txid, guard key hash, policy id, reward-account hash) has the wrong length parses to `Left` through the public parser entry | the parser crashes or accepts it |
| INV-4 | `lib/` contains no partial composition over `hashFromBytes`, and `DisburseIntentJSON` defines no hash helper of its own | either survives |
| INV-5 | `just golden`, `just schema-check`, `just smoke` green, no golden or schema file changed | any golden/schema diff or failure |

## Non-goals

- Test-only fixtures under `test/` that build constant hashes
  partially (`test/golden/Support/*Fixtures.hs`, devnet `SmokeSpec`)
  are not production and are not changed beyond what compilation of
  the new API requires.
- Error-message wording of existing `decodeHexBytes` failures is not
  changed.
