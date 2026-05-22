# 218 — reorganize-wizard mainnet path

## Context

Issue: [#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218)
Parent epic: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
Predecessors:

- [#212](https://github.com/lambdasistemi/amaru-treasury-tx/issues/212)
  — phase-2 scopes-NFT reference (merged in PR #214, `5bb75425`).
- [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217)
  — wizard UTxO selection filter (merged in PR #219, `cc6ba631`).

This is the **epic exit**: the deliverable is one validated mainnet
reorganize transaction body on disk, built by the shipped CLI from
real on-chain state.

## Root cause of the current block

The wizard explicitly refuses any non-devnet network at
`lib/Amaru/Treasury/Cli/ReorganizeWizard.hs:313-318`:

```haskell
runReorganizeWizardEither g opts = do
    case resolveNetworkName g of
        Right "devnet" -> stepOut
        Right other ->
            pure (Left (ReorganizeNonDevnetNetwork other))
        Left _ ->
            pure (Left (ReorganizeNonDevnetNetwork "<unresolved>"))
```

This was a deliberate Slice-1 stub
([#187](https://github.com/lambdasistemi/amaru-treasury-tx/issues/187)).
Every downstream surface is already network-agnostic:

- `Build.hs:155-163` `SReorganize` does **not** call `requireDevnet`.
- `resolveNetworkName` accepts `mainnet|preprod|preview|devnet`.
- `parseNetwork` (`IntentJSON/Common.hs:123`) maps each to ledger
  `Network` (`Mainnet`/`Testnet`).
- `withLocalNodeBackend` takes the operator-provided
  `--network-magic`, so it talks to any synced node.
- After #217 the wizard's UTxO selection drops script-deploy outputs
  on any address, mainnet included.

## P1 user story — operator command

Operator runs, against a synced mainnet `cardano-node` and the
canonical journal metadata:

```bash
amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  reorganize-wizard \
    --metadata /code/amaru-treasury/journal/2026/metadata.json \
    --scope <real scope> \
    --wallet-addr <operator wallet bech32> \
    --funding-seed-txin <real funded UTxO at that wallet> \
    --out /tmp/mainnet-reorganize.intent.json

amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  tx-build \
    --intent /tmp/mainnet-reorganize.intent.json \
    --out /tmp/mainnet-reorganize.cbor.hex
```

Result: a Conway-era tx body on disk that **phase-1 + phase-2
validate** against live mainnet protocol parameters. Signing and
submission stay outside this PR (the existing vault tooling under
`docs/manual.md` handles that).

## Owned-files surface

- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` — replace the
  devnet-only pattern with a "any-resolved-network" pattern. Rename
  the error variant from `ReorganizeNonDevnetNetwork Text` to
  `ReorganizeUnresolvedNetwork` (keeps the typed error surface but
  describes the actual failure mode — only an unresolved network is
  fatal now). Update the error printing and the exit-code map.
- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` — the
  `ReorganizeError` data type definition + the projection that
  renders the error. Rename the constructor.
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` and
  `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` — adjust any
  test that pattern-matches `ReorganizeNonDevnetNetwork` (and add a
  RED test confirming `--network mainnet` is no longer rejected).
- Possibly `lib/Amaru/Treasury/Tx/ReorganizeWizard/Trace.hs` if a
  trace constructor names the old variant.

## Live-boundary artifact (load-bearing)

The acceptance is **not** "unit tests pass". The acceptance is **one
valid mainnet tx body on disk**, archived in this PR.

The artifact is produced by running the operator command above
against `/code/cardano-mainnet/ipc/node.socket` (a synced mainnet
node already running locally as verified in #218 prep). The PR body
cites:

- `intent.json` content (chosen scope + outrefs)
- `tx-build` log
- `cbor.hex` length / blake2b
- `tx-inspect` summary

If the operator cannot provide a real funded wallet UTxO during this
PR's lifetime, the PR remains in draft until the artifact is
produced — there is no merge without this evidence.

## Acceptance criteria

1. `nix develop -c just ci` green.
2. Unit RED-then-GREEN: at least one test in
   `ReorganizeWizardParserSpec.hs` or `ReorganizeWizardSpec.hs` that
   asserts `--network mainnet` no longer produces
   `ReorganizeNonDevnetNetwork`; fails on `origin/main`, passes at
   HEAD.
3. The shipped exe accepts `--network mainnet` against
   `reorganize-wizard` and emits an `intent.json` whose
   `reorganize.network` field is `"mainnet"`.
4. **Mainnet tx body produced and archived in the PR.** Phase-1 +
   phase-2 validate against live mainnet protocol params.
5. `gate.sh` passes before push.

## What this PR does NOT deliver

- Mainnet **submission** (out of scope per the epic — the CLI is
  build-only).
- Lifting the equivalent guard on `GovernanceWithdrawalInitWizard` or
  `StakeRewardInitWizard` — those are init/bootstrap commands that
  legitimately should remain devnet-only.
- The devnet end-to-end smoke pass (tracked at
  [#222](https://github.com/lambdasistemi/amaru-treasury-tx/issues/222);
  unrelated to this PR).

## Operator preconditions to produce the artifact

The operator must supply:

1. A mainnet wallet address `BECH32` they control (or can read from).
2. A funded UTxO at that wallet, by `TxId#Ix`, with enough lovelace
   to cover fuel + collateral + reorganize tx fee. The wizard does
   not consume it (build-only PR); only the build phase queries it
   for fuel.
3. The scope to drive (one of `core_development`,
   `ops_and_use_cases`, `network_compliance`, `middleware`,
   `contingency` — all five live in the canonical journal metadata).

If any of these isn't available, surface that as the blocker; do not
fake a mainnet artifact.
