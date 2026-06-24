# Issue 410 Specification: Devnet PlutusV2 Cost Model

## Primary Story

As a maintainer proving swap re-rate against the local DevNet, I need
the DevNet to start with a PlutusV2 cost model in Conway protocol
parameters so the CLI re-rate smoke executes and reaches phase-2
validation instead of skipping.

## Requirements

- The DevNet host must preserve or install PlutusV1, PlutusV2, and
  PlutusV3 cost models in the initial Conway protocol parameters at
  node bring-up.
- The solution must use genesis initialization only. It must not use a
  runtime governance `ParameterChange` or era-schedule workaround.
- The `rerate` phase must continue to fail closed if the running node
  still lacks PlutusV2, but the expected path is execution rather than
  the old #410 loud skip.
- The unit smoke guard must assert the new genesis cost-model path and
  reject the old skip-only contract.
- The submitted `just devnet-cli-smoke --phase rerate` transcript must
  be captured under `specs/410-devnet-v2-costmodel/evidence/` and show
  phase-2 acceptance plus the old/new order UTxO transition.

## Success Criteria

- `nix develop --quiet -c just unit "CliDevnetSmoke"` passes.
- `just devnet-cli-smoke --phase rerate` runs rather than printing the
  #410 skip message.
- The committed evidence log contains the phase-2 acceptance and order
  UTxO flip proof from the live DevNet run.
