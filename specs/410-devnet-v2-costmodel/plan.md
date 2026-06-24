# Issue 410 Plan

## Scope

Owned code is limited to the DevNet smoke harness and its direct unit
guard: `app/devnet-cli-smoke-host/Main.hs`,
`test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs`, and the
`specs/410-devnet-v2-costmodel/` artifacts. Re-rate product code,
swap builders, API, and UI remain read-only.

## Technical Approach

The DevNet host already copies the pinned cardano-node-clients genesis
directory and patches Shelley/Conway governance parameters before
calling `withCardanoNode`. The likely missing piece is that the patched
Conway genesis does not carry the Alonzo PlutusV2 cost model into the
initial Conway PParams. The fix is to derive or preserve the V1/V2 cost
model payload from `alonzo-genesis.json` and write it into the Conway
genesis initial protocol parameters alongside the existing V3 model.

The runtime guard remains as a final assertion against the live node, but
its message should represent an impossible harness failure rather than
the expected behavior.

## Slices

1. **Genesis cost-model patch**: add RED unit coverage for the new
   source-level contract, then implement genesis-initial cost-model
   preservation without governance.
2. **Rerate wallet-address handoff**: update the DevNet host rerate
   setup to export the wallet address expected by the current
   `swap-rerate` CLI surface, preserving the genesis-only cost-model
   path from Slice 1.
3. **Executed re-rate proof**: run the real `rerate` DevNet smoke,
   capture the transcript, and commit the evidence.

## Verification

- Focused unit gate: `./gate.sh`.
- Live boundary proof: `nix develop --quiet -c just devnet-cli-smoke
  --phase rerate` with transcript captured to
  `specs/410-devnet-v2-costmodel/evidence/devnet-rerate.log`.
