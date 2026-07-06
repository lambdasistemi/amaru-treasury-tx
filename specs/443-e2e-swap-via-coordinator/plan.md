# Implementation Plan: Devnet Treasury Swap Via Coordinator

## Context

`treasury-swap-full-e2e` already proves the deploy, multi-owner roster,
Sundae pool, `swapProgram`, scoop, and final treasury-value path. Its
manual tail signs and submits directly with requester plus both owners.

#443 keeps that scaffold and replaces the manual tail with a live
coordinator path:

1. requester pre-witnesses the fuel/collateral input,
2. client obtains a coordinator fee quote,
3. client pays the fee via `cardano-cli` with metadata label `9721`,
4. coordinator indexer observes the payment,
5. entry is published and discovered by each owner,
6. owners upload witnesses,
7. coordinator submits,
8. existing Sundae scoop and treasury value assertions run.

## Q-001 Resolution

Q-001 answered on 2026-07-06 with Option 1 approved. Current
`/code/cardano-multisig` returns fee-status JSON using
`ready_to_publish`; the #442 amaru client currently decodes the
invented `paid` field. #443 owns the fix because the live boundary
proved the client cannot decode the real coordinator response.

Slice 1 must correct the client decoder and workflow readiness gate to
the authoritative coordinator contract:

- `observed`
- `confirmed`
- `sufficient`
- `ready_to_publish`
- `paid_lovelace`
- `required_lovelace`
- `confirmations`
- `reason`

## Coordinator Wiring

Do not vendor `cardano-multisig`. The smoke should start the external
coordinator with one of these operator-controlled paths:

- preferred override: `CARDANO_MULTISIG_SERVER=/path/to/cardano-multisig-server`;
- default local flake: `nix run --quiet /code/cardano-multisig#cardano-multisig-server`;
- optional override: `CARDANO_MULTISIG_FLAKE=/path/or/flake/ref`.

The child process receives:

- `NETWORK=devnet`
- `PORT=<allocated test port>`
- `CARDANO_NODE_SOCKET=<same devnet socket>`
- `CARDANO_NODE_MAGIC=42`
- `CARDANO_MULTISIG_STORE=<runDir>/treasury-swap-via-coordinator/store`
- `FEE_ADDRESS=<funded fee address>`
- `BASE_LOVELACE=1000000`
- `RATE_LOVELACE_PER_SLOT=0`
- `TTL_HORIZON_SLOTS=<large enough for the swap validity>`
- `FEE_INDEXER_CHECKPOINT_DIR=<phaseDir>/fee-indexer`
- a short `FEE_INDEXER_RETRY_DELAY_MICROS` for devnet polling.

## Slice 1: Coordinator Contract Compatibility

Goal: make the #442 client compatible with the merged coordinator
fee-status wire shape approved by Q-001.

Owned files:

- `lib/Amaru/Treasury/Coordinator/Client.hs`
- `lib/Amaru/Treasury/Coordinator/Workflow.hs`
- `test/unit/Amaru/Treasury/Coordinator/ClientSpec.hs`
- `test/unit/Amaru/Treasury/Coordinator/WorkflowSpec.hs`

Forbidden files:

- `test/devnet/**`
- swap builder / on-chain modules
- `/code/cardano-multisig/**`

Proof:

- RED: focused client/workflow unit test fails against a real
  `ready_to_publish` fee-status response copied from the authoritative
  coordinator contract.
- GREEN: focused unit tests pass.
- Gate: `./gate.sh`.

Commit:

`fix: align coordinator fee-status client`

Tasks trailer:

`Tasks: T443-S1`

## Slice 2: Named Devnet Smoke Through Coordinator

Goal: add `treasury-swap-via-coordinator` as a live devnet smoke phase
that reuses the existing full-swap scaffold and proves the complete
coordinator path.

Owned files:

- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- `scripts/smoke/devnet-local`
- `justfile`
- `amaru-treasury-tx.cabal` if the smoke needs an added dependency
- `docs/local-devnet-smoke.md` if the operator runbook needs an entry

Forbidden files:

- swap builder / on-chain modules
- `/code/cardano-multisig/**`
- production CLI behavior outside the coordinate client path

Proof:

- RED: focused devnet smoke fails before implementation because the new
  phase is not registered or the live coordinator assertions are absent.
- GREEN: `just devnet-smoke treasury-swap-via-coordinator` passes and
  summary artifacts show fee-status `fee_not_seen -> ready_to_publish`,
  owner discovery, two uploaded owner witnesses, submit receipt, scoop
  evidence, and final treasury value.
- Gate: `./gate.sh`.

Commit:

`test(devnet): swap treasury through coordinator`

Tasks trailer:

`Tasks: T443-S2`

## Finalization

1. Re-run `./gate.sh`.
2. Run the named live smoke:
   `nix develop --accept-flake-config -c just devnet-smoke treasury-swap-via-coordinator`.
3. Update PR body with delivered evidence and `Closes #443`.
4. Drop `gate.sh` in `chore: drop gate.sh (ready for review)`.
5. Mark PR ready for review.
6. Wait for GitHub Actions `CI` to pass; ignore the docs workflow.
7. Do not merge.
