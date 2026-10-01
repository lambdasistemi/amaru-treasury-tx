# spec — #32 Swap permissions reward account ignores the intent network

## Problem

`translateSwap` (`lib/Amaru/Treasury/IntentJSON.hs`) builds the
permissions reward account through `parseRewardAccount`, which pins
the ledger network to `Mainnet`. A swap intent declaring `preprod`,
`preview` or `devnet` therefore yields a mainnet reward account
(`stake1…`), silently, while every other action (disburse, withdraw,
reorganize, …) already honours the intent network through
`parseRewardAccountForNetwork`.

## User story

US-1 — As an operator building a swap on a non-mainnet network, the
swap's permissions reward account carries the intent's network, so
the withdrawal-zero / permissions credential is valid on that chain.

## Requirements

- REQ-1 — The swap translation derives the permissions reward
  account network from the intent's `network` field, with the same
  mapping the other actions use (`mainnet` → `Mainnet`;
  `preprod`/`preview`/`devnet` → `Testnet`).
- REQ-2 — An unknown network name in a swap intent is rejected by
  the translation with the existing reward-account network error,
  not defaulted to mainnet.
- REQ-3 — The mainnet-defaulting `parseRewardAccount` is removed
  from the library (definition and every re-export) in the same
  change; no caller remains.
- REQ-4 — Mainnet swap output is unchanged: every existing golden
  fixture is byte-identical.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | translating a swap intent with `network` ∈ {preprod, preview, devnet} yields a permissions `AccountAddress` whose network is `Testnet` | it is `Mainnet` (current `main`) |
| INV-2 | translating a mainnet swap intent yields `Mainnet` and goldens are byte-identical | any golden diff |
| INV-3 | no symbol `parseRewardAccount` (exact name) is defined or exported anywhere in `lib/`, `app/`, `test/` | the symbol still exists |
| INV-4 | a swap intent with an unrecognised network fails translation (`Left`) | it succeeds |

## Non-goals

- #33 (`fromJust . hashFromBytes`) — separate ticket.
- Any change to `parseRewardAccountForNetwork`, `parseNetwork`, the
  intent schema, or non-swap actions.
- Updating historical `specs/00*/` documents that mention the old name.
