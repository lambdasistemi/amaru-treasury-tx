# Tasks — 218 reorganize-wizard mainnet path

Owning doc: `specs/218-reorganize-wizard-mainnet/{spec,plan}.md`.

## Bootstrap

- [X] T000 — Bootstrap worktree + `gate.sh` + draft PR. Commit
  `15b62979`.

## S1 — Lift the devnet-only guard

Commit subject:

```
feat(reorganize-wizard): admit any resolved network (mainnet, preprod, preview, devnet)
```

- [ ] T001 — RED: unit test asserts `--network mainnet` no longer
  produces `ReorganizeNonDevnetNetwork`; must fail on `origin/main`.
- [ ] T002 — GREEN: rename `ReorganizeNonDevnetNetwork Text` →
  `ReorganizeUnresolvedNetwork`, replace the pattern match in
  `runReorganizeWizardEither`, update `exitCodeFor`, fix all
  call sites. `./gate.sh` green.

## S2 — Produce the live mainnet tx body (load-bearing)

- [ ] T003 — Build a real reorganize transaction body against
  `/code/cardano-mainnet/ipc/node.socket` and
  `/code/amaru-treasury/journal/2026/metadata.json` for the chosen
  scope. Archive `intent.json`, `cbor.hex`, and `tx-inspect` summary
  in the PR body. **PR remains draft until this artifact exists.**

## S3 — Finalize

- [ ] T004 — `./gate.sh`, `git rm gate.sh`, push, `gh pr ready 223`,
  merge.

## Cross-references

- Guard site:
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs:313-318` and
  the error variant in
  `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs`.
- Build-path proof reorganize is NOT in `requireDevnet`:
  `lib/Amaru/Treasury/Build.hs:155-163` (no `requireDevnet`
  call for `SReorganize`).
- Network parsers:
  `lib/Amaru/Treasury/Cli/Common.hs:146-157` `resolveNetworkName`;
  `lib/Amaru/Treasury/IntentJSON/Common.hs:123` `parseNetwork`.
- Local mainnet socket: `/code/cardano-mainnet/ipc/node.socket`
  (docker `cardano-mainnet`, Conway-synced).
- Canonical mainnet metadata: `/code/amaru-treasury/journal/2026/metadata.json`.
