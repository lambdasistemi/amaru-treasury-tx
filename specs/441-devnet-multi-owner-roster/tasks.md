# Tasks: #441 Devnet Multi-Owner Roster

## Slice S1 - Registry Roster Support

- [X] T441-S1 Add an opt-in devnet registry publication path that can
  publish distinct per-scope owner key hashes while preserving the
  existing singleton-owner default.
- [X] T441-S1 Add RED/GREEN proof at the lowest practical layer that
  the devnet registry path can carry at least two distinct owners.
- [X] T441-S1 Run the focused proof and `./gate.sh`.
- [X] T441-S1 Commit with subject
  `feat(devnet): support multi-owner registry rosters` and trailer
  `Tasks: T441-S1`.

## Slice S2 - Full Swap Requester/Fuel Wiring

- [X] T441-S2 Derive deterministic owner keys and a distinct requester
  key in `treasury-swap-full-e2e`, using the existing genesis-style
  seed derivation.
- [X] T441-S2 Fund owner and requester addresses using the existing
  genesis-funded transaction helper pattern.
- [X] T441-S2 Select swap fuel/collateral from the requester wallet,
  set at least two owner `fsiSigners`, and sign the built swap with
  requester plus owner keys.
- [X] T441-S2 Write owner/requester key artifacts or a manifest under
  the run directory for #443.
- [X] T441-S2 Run the focused devnet smoke and `./gate.sh`.
- [X] T441-S2 Commit with subject
  `feat(devnet): use multi-owner swap roster` and trailer
  `Tasks: T441-S2`.

## Finalization

- [X] T441-F1 Verify every implementation task is checked.
- [X] T441-F1 Run `./gate.sh` at HEAD.
- [X] T441-F1 Run the focused `treasury-swap-full-e2e` devnet smoke
  at HEAD or record why an already-fresh successful run still applies.
- [X] T441-F1 Update the PR body so it contains `Closes #441`.
- [X] T441-F1 Drop `gate.sh` in the final ready-for-review commit.
- [X] T441-F1 Mark the PR ready only after GitHub CI is green.
