# Tasks: #453 Log Verbosity Control

## Slice 1 - Shared parsing and CLI plumbing

- [ ] T453-S1 Add shared severity parsing/rendering.
- [ ] T453-S1 Extend CLI global config with log level and verbose
  parsing.
- [ ] T453-S1 Thread the resolved threshold into N2C provider tracing.
- [ ] T453-S1 Add/update focused unit tests and run slice proof.
- [ ] T453-S1 Commit `feat: add CLI log verbosity control`.

## Slice 2 - API environment and provider wiring

- [ ] T453-S2 Resolve `AMARU_TREASURY_LOG_LEVEL` in API startup config.
- [ ] T453-S2 Log the resolved API log level once at startup.
- [ ] T453-S2 Apply the resolved threshold to API/indexer provider
  tracing.
- [ ] T453-S2 Add/update focused unit tests and run slice proof.
- [ ] T453-S2 Commit `feat: add API log verbosity env control`.

## Finalization

- [ ] T453-F1 Run the full `./gate.sh` at branch head.
- [ ] T453-F1 Update the draft PR body with delivered behavior and
  verification.
- [ ] T453-F1 Drop `gate.sh`, mark the PR ready, and wait for CI.
