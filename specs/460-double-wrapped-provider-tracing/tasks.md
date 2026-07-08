# Tasks

## Slice 1 - Provider Trace Construction

- [ ] T460-S1 Update `indexerProvider` so only indexer-created UTxO
  closures receive API-side trace wrappers.
- [ ] T460-S1 Preserve direct `withLocalNodeBackend` and
  `withLocalNodeClient` `tracedProvider` coverage.
- [ ] T460-S1 Update focused regression coverage in
  `test/unit/Amaru/Treasury/Trace/ProviderSpec.hs`.
- [ ] T460-S1 Run focused provider tests plus format and hlint checks.
- [ ] T460-S1 Commit as
  `fix: avoid double provider tracing through indexerProvider` with
  trailer `Tasks: T460-S1`.

## Slice 2 - Verification And Finalization

- [ ] T460-S2 Run `./gate.sh` from the issue worktree and record the
  result.
- [ ] T460-S2 Attempt live/devnet duplicate-trace verification or record
  why it is not practical from this host.
- [ ] T460-S2 Update PR #463 with delivered behavior and evidence.
- [ ] T460-S2 Drop `gate.sh` in the final readiness commit.
- [ ] T460-S2 Wait for GitHub Actions to finish green at the final
  pushed head before logging `COMPLETE`.
