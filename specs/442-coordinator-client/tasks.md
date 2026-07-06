# Tasks: Coordinator Client

## Slice 1 - Wire Client

- [X] T442-S1 Define `/v1` request/response types and typed client
  errors in `lib/Amaru/Treasury/Coordinator/Client.hs`.
- [X] T442-S1 Add JSON round-trip and URL/path/method tests in
  `test/unit/Amaru/Treasury/Coordinator/ClientSpec.hs`.
- [X] T442-S1 Register new modules/tests in `amaru-treasury-tx.cabal`.
- [X] T442-S1 Run focused proof:
  `nix develop --accept-flake-config -c just unit "Coordinator.Client"`.
- [X] T442-S1 Commit as
  `feat: add coordinator v1 client types`
  with trailer `Tasks: T442-S1`.

Owned files:

- `lib/Amaru/Treasury/Coordinator/Client.hs`
- `test/unit/Amaru/Treasury/Coordinator/ClientSpec.hs`
- `amaru-treasury-tx.cabal`

## Slice 2 - Coordination Workflow

- [ ] T442-S2 Define the ordered coordination workflow in
  `lib/Amaru/Treasury/Coordinator/Workflow.hs`.
- [ ] T442-S2 Reuse `createWitness` and `attachWitnesses` for
  requester pre-witness and owner witnesses.
- [ ] T442-S2 Add stub coordinator tests in
  `test/unit/Amaru/Treasury/Coordinator/WorkflowSpec.hs` proving body
  hash validation, pre-witness preservation, call ordering, owner
  uploads, and submit receipt handling.
- [ ] T442-S2 Register new modules/tests in `amaru-treasury-tx.cabal`.
- [ ] T442-S2 Run focused proof:
  `nix develop --accept-flake-config -c just unit "Coordinator.Workflow"`.
- [ ] T442-S2 Commit as
  `feat: coordinate witness collection workflow`
  with trailer `Tasks: T442-S2`.

Owned files:

- `lib/Amaru/Treasury/Coordinator/Client.hs`
- `lib/Amaru/Treasury/Coordinator/Workflow.hs`
- `test/unit/Amaru/Treasury/Coordinator/WorkflowSpec.hs`
- `amaru-treasury-tx.cabal`

## Slice 3 - CLI And Fee Payment

- [ ] T442-S3 Add the fee-payment boundary in
  `lib/Amaru/Treasury/Coordinator/FeePayment.hs`, paying the
  coordinator fee with metadata label `9721 = body_hash`.
- [ ] T442-S3 Add `coordinate` parser/runner in
  `lib/Amaru/Treasury/Cli/Coordinate.hs`.
- [ ] T442-S3 Wire `CmdCoordinate` into
  `lib/Amaru/Treasury/Cli.hs` and `app/amaru-treasury-tx/Main.hs`.
- [ ] T442-S3 Add parser/runner tests in
  `test/unit/Amaru/Treasury/Cli/CoordinateSpec.hs` and focused
  fee-payment tests in
  `test/unit/Amaru/Treasury/Coordinator/FeePaymentSpec.hs`.
- [ ] T442-S3 Register new modules/tests in `amaru-treasury-tx.cabal`.
- [ ] T442-S3 Run focused proof:
  `nix develop --accept-flake-config -c just unit "Coordinate"`.
- [ ] T442-S3 Commit as
  `feat: expose coordinator client cli`
  with trailer `Tasks: T442-S3`.

Owned files:

- `lib/Amaru/Treasury/Coordinator/Client.hs`
- `lib/Amaru/Treasury/Coordinator/Workflow.hs`
- `lib/Amaru/Treasury/Coordinator/FeePayment.hs`
- `lib/Amaru/Treasury/Cli/Coordinate.hs`
- `lib/Amaru/Treasury/Cli.hs`
- `app/amaru-treasury-tx/Main.hs`
- `test/unit/Amaru/Treasury/Cli/CoordinateSpec.hs`
- `test/unit/Amaru/Treasury/Coordinator/FeePaymentSpec.hs`
- `amaru-treasury-tx.cabal`

## Finalization

- [ ] T442-F1 Run
  `nix develop --accept-flake-config -c just ci`.
- [ ] T442-F2 Push branch and ensure the draft PR body contains
  `Closes #442`.
- [ ] T442-F3 Drop `gate.sh` if present.
- [ ] T442-F4 Mark PR ready for review.
- [ ] T442-F5 Verify GitHub Actions `CI` is green and ignore
  `Build and deploy documentation`.
- [ ] T442-F6 Append `READY` and `COMPLETE` to
  `/tmp/amaru-int/ticket-442/STATUS.md`.
