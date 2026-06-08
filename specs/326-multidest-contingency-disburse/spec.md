# Spec — Multi-destination contingency disburse (#326)

Parent epic: https://github.com/lambdasistemi/amaru-treasury-tx/issues/325

## P1 user story

As a treasury operator, I run `contingency-disburse-wizard` with
multiple destination scopes and ADA amounts and produce one unsigned
transaction that pays each scope its ADA from the contingency treasury.

## Background / feasibility (settled)

The Sundae treasury validator does **not** constrain the number or
ordering of payout outputs. Confirmed against upstream
`logic/treasury/disburse.ak` @`8a3183c929be57886214624b45ee0c43a0c19277`:
the only rule is conservation on the treasury script outputs —
`equal_plus_min_ada(merge(input_sum, negate(amount)), output_sum)`.
The Disburse redeemer (`Constr 3 [Map policy→asset→qty]`) authorizes a
**total** `amount` leaving the treasury; that total may be split across
N beneficiary outputs to different addresses. No validator change, no
new redeemer.

## User stories

- US1 — Operator builds a 1..N destination contingency disburse from the
  CLI and gets one unsigned tx with N beneficiary outputs + the treasury
  leftover.
- US2 — Operator is refused when a destination is `Contingency` or when
  the destination list is empty.
- US3 — A 1-destination disburse is byte-identical to today's output
  (the multi-destination model is a strict generalization; N=1 is the
  existing behavior).

## Functional requirements

- FR1 — The typed disburse intent carries a **non-empty list** of ADA
  beneficiary outputs `(beneficiary address, lovelace)` instead of a
  single beneficiary + amount.
- FR2 — `disburseAdaProgram` emits one `payTo` per beneficiary output
  plus exactly one treasury leftover `payTo`. The spend redeemer
  `amount` = Σ beneficiary lovelace; leftover lovelace = treasury input
  − Σ.
- FR3 — `resolveDisburseEnvIC` / `disburseToTreasuryIntent` compute the
  leftover and required treasury value against the summed amount.
- FR4 — The intent JSON schema represents the destination list; golden
  fixtures cover a 2-destination ADA disburse, and the N=1 golden is
  unchanged byte-for-byte.
- FR5 — `contingency-disburse-wizard` accepts a repeatable destination
  flag `--to <scope>:<ada>`; rejects `Contingency` as a destination and
  rejects an empty destination set; each destination scope's treasury
  address is resolved from verified metadata.
- FR6 — A devnet test builds AND submits a 2-destination contingency
  disburse and asserts on-chain acceptance (live-boundary proof).

## Success criteria

- `just ci` green in the worktree.
- New 2-destination golden CBOR fixture; existing single-destination
  goldens unchanged.
- Devnet proof test passes against the local devnet node.
- `contingency-disburse-wizard --to a:100 --to b:50 ...` writes an
  unsigned `intent.json` / tx with 3 outputs (2 beneficiaries + leftover).

## Exclusions (non-goals)

- No HTTP API or UI (sibling child #327).
- ADA only — multi-destination USDM is out of scope.
- No new redeemer or validator change.
- Generic `disburse-wizard` keeps its single-beneficiary operator
  surface; only the underlying model is generalized (it passes a
  singleton list). No multi-beneficiary flag on the generic wizard.

## Command-recovery

Yes. Operator command:
`amaru-treasury-tx contingency-disburse-wizard --to <scope>:<ada> [--to ...]`.
The shipped CLI is the P1 surface; the devnet submission is the proof,
not a substitute.
