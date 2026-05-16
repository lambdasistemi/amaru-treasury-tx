# Command Gap Correction

state: ResolvedByCommandSlice

## Finding

The first #147 implementation delivered a production-backed
`registry-init` smoke phase, but it did not deliver a shipped
`amaru-treasury-tx` command. Parent issue #151 is explicitly command
recovery for operator-created bootstrap transactions, so a smoke-only
command surface is insufficient.

## Required Correction

- Treat the production CLI command as a P1 #147 user story.
- Carry this forward as a parent #151 invariant: #148, #149, and #150
  must each start with the shipped operator command as the paramount P1
  user story. Smoke proof is evidence for the command, not a replacement
  for the command.
- Keep `Amaru.Treasury.Devnet.RegistryInit` as the transaction
  construction owner.
- Add a thin shipped DevNet command around that module.
- Keep normal release-facing build commands build-only by rejecting
  non-DevNet networks in the new command.
- Prove the command path with focused parser/runner tests and the live
  `just devnet-smoke registry-init` proof.

## Next Actor

Resolved by Dalton's T035-T042 command slice at
`663c0e2fd57d54a2cf2c8c669b31f209ada26451`. The orchestrator reviewed
the diff, sent output-contract and HLint corrections back to the same
subagent, reran local verification, updated docs/spec metadata, and
returned #147 to final PR review.
