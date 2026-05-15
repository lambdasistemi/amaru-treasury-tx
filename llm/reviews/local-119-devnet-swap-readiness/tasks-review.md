# Tasks Review: DevNet Swap Contract Readiness

## Verdict

Approved for T006/T007 RED work.

## Checks

- Tasks are ordered spec/process -> RED -> artifact pin -> DevNet
  publication -> diagnostics -> docs.
- RED task is explicit and must be observed before production edits.
- The public artifact and DevNet publication land in one bisect-safe
  vertical slice once the proof exists.
- Docs and issue metadata are included after verified evidence.

## Required Evidence Before Code Handoff

- Focused RED command output showing the missing readiness contract.
- `just devnet-smoke swap-ready` GREEN run directory with registry
  path, order script hash, and reference-script UTxO.
- Local gate output from `llm/reviews/local-119-devnet-swap-readiness/gate.sh`.
