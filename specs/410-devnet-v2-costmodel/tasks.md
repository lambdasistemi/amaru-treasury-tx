# Issue 410 Tasks

## Slice 1 - Genesis cost-model patch

- [X] T410-S1 Add a failing unit guard that expects the DevNet host to
  ensure Conway genesis carries PlutusV1, PlutusV2, and PlutusV3 cost
  models from genesis.
- [X] T410-S1 Implement the genesis initialization path without adding
  governance `ParameterChange` machinery or era-schedule changes.
- [X] T410-S1 Run `./gate.sh`, commit one bisect-safe slice, and leave
  the branch unpushed for orchestrator review.

## Slice 2 - Rerate wallet-address handoff

- [ ] T410-S2 Add a failing unit guard that expects the DevNet host to
  export `CLI_SMOKE_RERATE_WALLET_ADDRESS` for the rerate phase.
- [ ] T410-S2 Update the host rerate setup environment to pass the
  deterministic DevNet funding wallet address used by current
  `swap-rerate`.
- [ ] T410-S2 Run `./gate.sh`, commit one bisect-safe slice, and leave
  the branch unpushed for orchestrator review.

## Slice 3 - Executed rerate transcript

- [ ] T410-S3 Run `nix develop --quiet -c just devnet-cli-smoke --phase
  rerate` against the patched DevNet.
- [ ] T410-S3 Capture the full transcript at
  `specs/410-devnet-v2-costmodel/evidence/devnet-rerate.log`, including
  phase-2 acceptance and order UTxO transition evidence.
- [ ] T410-S3 Run `./gate.sh`, commit one bisect-safe evidence slice,
  and leave the branch unpushed for orchestrator review.
