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

- [X] T001 — RED: unit test asserts `--network mainnet` no longer
  produces `ReorganizeNonDevnetNetwork`; must fail on `origin/main`.
- [X] T002 — GREEN: rename `ReorganizeNonDevnetNetwork Text` →
  `ReorganizeUnresolvedNetwork`, replace the pattern match in
  `runReorganizeWizardEither`, update `exitCodeFor`, fix all
  call sites. `./gate.sh` green.

## S2 — Produce the live mainnet tx body (load-bearing)

- [X] T003 — Built a real mainnet reorganize transaction body for
  `core_development` against `/code/cardano-mainnet/ipc/node.socket`
  and `/code/amaru-treasury/journal/2026/metadata.json`. Operator
  wallet from `~/.config/amaru-treasury-tx/operator.json`. Surfaced
  one secondary issue — Conway's 64-byte per-metadatum-string cap
  rejected the wizard's default `rjDescription` (67 bytes) — and
  shipped the trivial shortening (59 bytes) in the same slice.
  `tx-build`: `built 1217 bytes  fee=428294  total_collateral=642441`
  / `re-evaluated 3 redeemers, 0 failed` / `VALIDATION OK`.
  `intent.json`, `tx-build.log`, and `reorganize.cbor.hex`
  (blake2b-256 `1872aaedf470eb59f90b9c72a7f97bb25d5f9bff6afbdf27d43a0a3cc11a78f0`)
  archived under `evidence/218-mainnet/` (untracked) and inlined in
  the PR body.

## S3 — Finalize

- [X] T004 — `./gate.sh`, `git rm gate.sh`, push, `gh pr ready 223`,
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
