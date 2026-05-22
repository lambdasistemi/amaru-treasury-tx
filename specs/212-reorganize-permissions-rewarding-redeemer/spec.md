# 212 — reorganize phase-2 validation: include scopes-NFT reference UTxO

## Context

Issue: [#212](https://github.com/lambdasistemi/amaru-treasury-tx/issues/212)
Parent epic: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
Predecessor: [#87 / PR #208 (merged at `7047f477`)](https://github.com/lambdasistemi/amaru-treasury-tx/pull/208)

The `reorganize-wizard --network devnet` → `tx-build --intent` chain
produces a transaction that fails Plutus phase-2 evaluation on the
permissions reward-account script (hash
`17e03cc22e4f0fb441d84c51125ddf39e857d168f3d4760444058f74`) when
invoked as a `ConwayRewarding` redeemer.

## Root cause (evidence-backed)

The Aiken permissions validator ignores the withdraw redeemer
(`permissions.ak:46` — `_redeemer: Data, _credential: Credential`)
and instead calls:

```aiken
expect_scopes(self.reference_inputs, scopes_nft)
```

(`permissions.ak:53,56,63,88`). `expect_scopes` (`lib/scope.ak:76-93`)
walks `reference_inputs` looking for the UTxO carrying the scopes-NFT
with `config.scopes_token_name`. When no such UTxO is present it emits
`trace "no scopes found in reference inputs for policy id"` and calls
`fail`. That fail surfaces as the CekError "error" recorded in #212.

The Haskell `reorganizeProgram`
(`lib/Amaru/Treasury/Tx/Reorganize.hs:94-96`) attaches **three**
reference inputs:

- `rgiTreasuryDeployedAt` — deployed treasury script
- `rgiRegistryDeployedAt` — registry NFT reference
- `rgiPermissionsDeployedAt` — deployed permissions script

It does **not** attach the scopes-NFT UTxO. By contrast, upstream bash
(`journal/2026/lib/build_transaction.sh:17-18` +
`load_permissions_config.sh:6`) attaches both `registry_reference` and
`scopes_reference` (loaded from `metadata.scope_owners`); and
`Amaru.Treasury.Tx.Disburse.DisburseIntentFields`
(`lib/Amaru/Treasury/Tx/Disburse.hs:84-91`) already carries
`difScopesDeployedAt` and `references` it in `disburseProgram`
(`Disburse.hs:171,214`). That asymmetry is the regression: the
reorganize intent shape and program were authored from
[#185](https://github.com/lambdasistemi/amaru-treasury-tx/issues/185)
without the scopes reference, even though the validator path is
identical to disburse's withdraw branch.

The withdraw redeemer (`List []`, from `emptyListRedeemer`) is
**correct** and matches the bash literal
`--withdrawal-reference-tx-in-redeemer-value "[]"`
(`build_transaction.sh:22`). The treasury spending redeemer
(`Constr 0 []`, from `reorganizeRedeemer`) is also **correct** and
matches `make_redeemer_reorganize.sh`. No change there.

## P1 user story — operator command

Operator runs the unchanged operator command:

```bash
nix develop -c just devnet-cli-smoke \
  --phase reorganize \
  --run-dir runs/devnet-cli/<stamp>
```

The smoke completes end-to-end:

1. `reorganize-wizard --network devnet` emits a valid `intent.json`
   that includes a `scopesDeployedAt` field loaded from
   `metadata.scope_owners`.
2. `tx-build --intent <intent.json>` constructs a Conway transaction
   that passes phase-1 (size, fees, witness count) **and phase-2
   (Plutus evaluation)** against a local devnet.
3. The transaction submits successfully and the on-chain
   `core_development` treasury collapses three UTxOs into one.

## Deliverables

- `lib/Amaru/Treasury/Tx/Reorganize.hs` — `ReorganizeIntent` gains
  `rgiScopesDeployedAt :: !TxIn`; `reorganizeProgram` emits a fourth
  `reference` line.
- `lib/Amaru/Treasury/Build/Reorganize.hs` — `refInputs` includes
  `rgiScopesDeployedAt`.
- `lib/Amaru/Treasury/IntentJSON.hs` — `ReorganizeInputs` gains
  `riScopesDeployedAt :: !TxIn`; `FromJSON` / `ToJSON` parse and emit
  `scopesDeployedAt`; intent-to-reorganize translation populates the
  new field.
- `lib/Amaru/Treasury/IntentJSON/Schema.hs` — schema gains the
  `scopesDeployedAt` field.
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` — wizard reads
  `metadata.scope_owners` (already parsed by
  `Amaru.Treasury.Metadata`) and writes it into the intent.
- `test/unit/Amaru/Treasury/IntentJSONSpec.hs` — RED: roundtrip /
  parser tests reject `scopesDeployedAt`-missing reorganize intents
  and roundtrip the new field.
- `test/golden/ReorganizeGoldenSpec.hs` — RED: the script-context
  assertion verifies the reorganize transaction includes the
  scopes-NFT reference UTxO; phase-2 evaluation against a frozen
  ChainContext passes for the merged 3-UTxO case.
- `specs/212-reorganize-permissions-rewarding-redeemer/{spec,plan,tasks}.md`.

This is a fix to an existing exe surface (`amaru-treasury-tx
reorganize-wizard` + `amaru-treasury-tx tx-build`), not a new
deliverable. No asciinema is required for the fix: #87 already owns
the smoke wiring, and #188 owns the operator-facing recording.

## Out of scope

- Any change to the upstream `cardano-treasury-contracts` Aiken
  validators.
- Any change to the `make_redeemer_reorganize` / `reorganizeRedeemer`
  shape or to `emptyListRedeemer`.
- Any change to the smoke harness shipped by #87 (#208).
- Operator docs / asciinema (owned by #188).

## Acceptance criteria

1. Phase-1 lint: `nix develop -c just ci` green at HEAD.
2. Phase-2 proof: `nix develop -c just devnet-cli-smoke --phase
   reorganize` produces a tx that evaluates without phase-2 error,
   submits, and confirms the merged treasury UTxO on the local
   devnet.
3. Unit RED-then-GREEN: at least one new test in
   `test/unit/Amaru/Treasury/IntentJSONSpec.hs` and one in
   `test/golden/ReorganizeGoldenSpec.hs` fails on `origin/main` and
   passes at HEAD.
4. `reorganize-wizard --network devnet` writes a JSON intent that
   includes the new `scopesDeployedAt` field, populated from the
   on-disk metadata `scope_owners` outref.
5. The `REORGANIZE_BUILD_FAILED` typed diagnostic shipped by #87 is
   preserved verbatim; the smoke happy path is recorded by #87's
   contract, not weakened.
6. `gate.sh` passes locally before push (`./gate.sh`).
