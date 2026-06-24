# Tasks — #409 treasury swap e2e on devnet (design A)

One bisect-safe slice. Items get `[X]` when the slice is accepted (orchestrator
amends in the same commit as the slice).

## Slice S1 — `treasury-swap-e2e` phase (treasury-destination order → scoop → treasury balance)

- [X] T409-S1-a  Derive the `CoreDevelopment` treasury target/hash and the
      treasury destination address (script payment + script stake); add
      `stakedScriptAddr` helper if needed. Verify it equals the address
      `swapOrderDatum` implies.
- [X] T409-S1-b  Add `placeTreasurySwapOrder`: order via shipped `swapOrderDatum`
      with treasury-script destination, `sodPoolId = spuIdent pool`, want-asset =
      test token, same locked value as the generic order.
- [X] T409-S1-c  Scoop the treasury order: route the swapped-token output to the
      treasury address (no-datum, matching the destination spec); keep pool out /
      withdraw-zero / redeemers / validity as the foundation. (Parameterize
      `scoopSundaeOrder` or add a treasury variant — keep `scoop-e2e` behaviour
      intact.)
- [X] T409-S1-d  Assert `orderConsumed == True` and
      `treasuryTokenQuantity >= 9_896_088`. RED first (assertion fails while the
      output still targets the wallet), then GREEN.
- [X] T409-S1-e  Add `TreasurySwapEvidence` + `writeTreasurySwap*` artifacts;
      `summary.json` records `orderConsumed`, `treasuryTokenQuantity`, `scoopTxId`,
      cascade hashes (phase `treasury-swap-e2e`).
- [X] T409-S1-f  Wire the phase: `it "treasury-swap-e2e: ..."` describe entry +
      `treasury-swap-e2e` in `scripts/smoke/devnet-local` allowlist + guard.
- [X] T409-S1-g  Proof: `./gate.sh` green; `--phase treasury-swap-e2e` GREEN at
      the live boundary (treasuryTokenQuantity>0 + scoop tx id in summary.json);
      `--phase scoop-e2e` still GREEN (no regression). Record evidence in WIP.md.
- [X] T409-S1-h  Commit (one bisect-safe slice), subject + `Tasks: T409-S1`
      trailer; do NOT push (orchestrator pushes after review).

## Finalization (orchestrator-owned)

- [ ] T409-FIN-a  Review diff; push; amend tasks checkboxes; update PR #412 body
      with the live-boundary artifact (summary.json + scoop tx id).
- [ ] T409-FIN-b  Drop `gate.sh` (`chore: drop gate.sh`); `gh pr ready 412`.
