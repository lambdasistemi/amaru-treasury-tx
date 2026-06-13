# Tasks: Operate to Pending Handoff

## Slice 1 - Save Built Operate Tx To Pending

- [X] T369-S1 Add a failing Playwright proof that saves a mocked
  Operate build to Pending and observes zero witnesses.
- [X] T369-S1 Add localized Operate save state/action/rendering for
  built transactions.
- [X] T369-S1 Persist through `Store.PendingTx.put` using
  `Api.introspectTx`, empty witnesses, TTL, required signers, and the
  rebuild recipe.
- [X] T369-S1 Run focused RED/GREEN proof, `./gate.sh`, navigator
  review, and commit one bisect-safe slice.

## Finalization

- [ ] T369-F1 Update PR metadata for the delivered behavior.
- [ ] T369-F1 Run final `./gate.sh` and finalization audit.
- [ ] T369-F1 Drop `gate.sh` in the final ready-for-review commit.
