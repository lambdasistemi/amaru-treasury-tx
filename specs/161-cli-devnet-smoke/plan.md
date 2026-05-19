# Implementation Plan: CLI DevNet Smoke Proof

**Branch**: `161-cli-devnet-smoke` | **Date**: 2026-05-19 | **Spec**: [spec.md](./spec.md)  
**Issue**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)  
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)

## Summary

Add a bash `scripts/smoke/smoke.sh` entrypoint and `just devnet-cli-smoke` target that prove the full bootstrap + disburse operator path through shipped `amaru-treasury-tx` commands against a real local DevNet. A small Haskell host executable may own only DevNet lifecycle, governance genesis patching, deterministic smoke key generation, and chain assertions. The transaction pipeline itself must be shell commands: wizard, `tx-build`, `vault create`, `witness`, `attach-witness`, `submit`.

The plan carries one explicit audit item: the existing library smoke submits a follow-up governance vote in process, while #157/#160 shipped only `governance-withdrawal-init-proposal` and `governance-withdrawal-init-materialization`. The CLI smoke must prove the patched DevNet genesis does not require a shipped vote tx, or it must fail with a missing-surface diagnostic and the PR stays draft until that surface is added or split into a new child.

## Technical Context

**Language/Version**: Bash plus Haskell (GHC via repository Nix shell)  
**Primary Dependencies**: `cardano-node-clients:devnet`, `cardano-node`, `cardano-cli`, `jq`, shipped `amaru-treasury-tx` executable  
**Storage**: Filesystem run directory under `runs/devnet-cli/<timestamp>` or an explicit `--run-dir`  
**Testing**: Hspec unit tests for no-fallback/static script behavior, shell preflight checks, live `just devnet-cli-smoke` run  
**Target Platform**: Linux Nix development shell  
**Project Type**: Haskell CLI with shell smoke harness  
**Performance Goals**: Complete within the same order of magnitude as the existing governance/disburse `SmokeSpec` phases; polling timeouts are explicit and configurable  
**Constraints**: No `runDevnet*`, no `Amaru.Treasury.Devnet.Runner`, no `cabal test devnet-tests`; `SmokeSpec` preserved unchanged; every behavior commit passes `./gate.sh`  
**Scale/Scope**: One live smoke entrypoint, one narrow DevNet host/helper, docs/just/gate wiring, and focused tests

## Constitution Check

- **I. Faithful port of the bash recipes**: PASS. This is a proof harness; it does not change disburse/withdraw/swap semantics.
- **II. Pure builders, impure shell**: PASS. The smoke shells the shipped CLI and does not move builder logic into the script.
- **III. Pluggable data source, local-node default**: PASS. The smoke targets the local N2C DevNet boundary only.
- **IV. Build, never sign or submit**: JUSTIFIED EXCEPTION FOR SMOKE ONLY. The shipped CLI remains build-first, but this DevNet smoke intentionally exercises `witness`, `attach-witness`, and `submit` as the operator proof. Key material is deterministic DevNet-only fixture material.
- **V. Test-first with golden CBOR fixtures**: PASS. This PR adds live-boundary proof on top of existing unit/golden parity; it does not replace goldens.
- **VI. Hackage-ready Haskell**: PASS. Any helper executable uses explicit modules, fourmolu, hlint, and `just ci`.
- **VII. Label-1694 metadata**: PASS. No rationale metadata shape changes.

## Live-Boundary Diagnostic

Question: what system boundary does this exercise that unit/golden tests cannot?

Answer: the shipped binary pipeline across a live node boundary: wizard chain queries, `tx-build` live context acquisition, vault-backed witness creation, witness attachment, node submission, governance reward accrual, materialized treasury UTxO observation, and disburse beneficiary receipt. This must be a live smoke, not an operator follow-up, because #161's acceptance target is exactly the live CLI proof.

The smoke is allowed to use helper code for node lifecycle and assertions, but the proof fails unless every transaction is built, signed, and submitted by shipped CLI commands.

## Project Structure

```text
specs/161-cli-devnet-smoke/
|-- spec.md
|-- plan.md
|-- tasks.md
`-- checklists/requirements.md

scripts/smoke/
`-- smoke.sh                         # new CLI proof entrypoint

app/devnet-cli-smoke-host/
`-- Main.hs                          # new narrow DevNet lifecycle host, if needed

test/unit/Amaru/Treasury/Smoke/
`-- CliDevnetSmokeSpec.hs            # new no-fallback/static behavior tests

justfile                             # new devnet-cli-smoke target
flake.nix                            # jq in dev shell if needed
amaru-treasury-tx.cabal              # host/test registration and extra source file
README.md
docs/local-devnet-smoke.md
gate.sh                              # extended while PR is draft; dropped before ready
```

`test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` is intentionally not edited except for mechanical cabal/test-suite registration fallout if the compiler requires it. The default plan is no body diff.

## Design Decisions

### DevNet Host Boundary

Use a tiny host executable if direct bash node lifecycle becomes brittle. The host may:

- copy the pinned genesis into the run directory;
- apply the governance short-epoch/deposit patch currently duplicated in `SmokeSpec`;
- call `withCardanoNode`;
- write deterministic DevNet signing-key envelopes for the genesis funding key and governance voter key;
- export `CARDANO_NODE_SOCKET_PATH`, network magic/name, funding address, key hashes, run-dir paths, and timeout values;
- execute `scripts/smoke/smoke.sh --inside-devnet`.

The host may not call `runDevnet*`, `Amaru.Treasury.Devnet.Runner`, `submitGovernanceWithdrawal`, `setupDevnetStakeRewards`, or any construction runner. It is infrastructure, not a transaction path.

### Shell Pipeline Shape

Each transaction step uses a shared shell function:

```text
wizard -> intent.json
tx-build --intent -> unsigned.cbor.hex + report.json
witness --tx --vault --identity -> witness.hex
attach-witness --tx --witness ... -> signed.cbor.hex
submit --tx -> txid
verify report txid == submitted txid
wait/assert chain effect
```

The script creates vaults through `amaru-treasury-tx vault create --signing-key-file ... --vault-passphrase-fd ...`, then signs with `witness --vault-passphrase-fd ...` using expected key hashes. Bootstrap txs must not use `--allow-unlisted-key`.

### Governance Vote Reachability

The current Haskell runner submits a separate in-process vote tx after the proposal. There is no shipped vote intent in #157 and no vote subcommand in #160. Therefore Slice 1 includes a reachability audit and Slice 3 carries the live proof:

- If the patched genesis causes proposal enactment/reward accrual without an explicit vote tx, the smoke records that observation and proceeds to materialization.
- If not, the smoke fails with `missing-shipped-governance-vote` and the PR remains draft. The next action is either adding a narrow shipped vote intent/subcommand in this PR with explicit parent update, or opening a new child ticket before #161 can merge.

No implementation may hide this by calling `submitVoteTx` or `runDevnetGovernanceWithdrawalInit`.

## Vertical Review Slices

1. **Slice 1 - Static no-fallback guard + planning audit.** Add `scripts/smoke/smoke.sh` scaffold, `just devnet-cli-smoke`, and unit/static tests that reject forbidden runner calls. Include a source-level audit note/test for the governance vote reachability gap.
2. **Slice 2 - DevNet host + key/vault preflight.** Add the narrow host, patched genesis preparation, deterministic key fixture export, dependency preflight, run-dir layout, vault creation, and a smoke dry-run mode that proves `vault create`/`witness` can sign a fixture tx without DevNet transaction construction.
3. **Slice 3 - Registry + stake/reward CLI phases.** Implement seed-split, mint, reference-scripts, script-account, and plain-account through shipped CLI commands; record tx ids and verify registry/accounts artifacts and chain anchors.
4. **Slice 4 - Governance materialization CLI phase.** Implement proposal, governance reward/enactment wait, materialization, and materialized treasury UTxO verification. This is the slice that either proves no shipped vote is required under patched genesis or returns the explicit missing-surface failure.
5. **Slice 5 - Disburse CLI phase + final summary.** Run `disburse-wizard`, build/sign/submit, verify beneficiary receipt and treasury reduction, and write final summary.
6. **Slice 6 - Docs, gate extension, and runner-retention decision.** Update README/local smoke docs, PR body, and `gate.sh`. Decide whether `lib/Amaru/Treasury/Devnet/*Init.hs` runners remain for `SmokeSpec`; default is to keep them and document why.
7. **Slice 7 - Finalization.** Full local gate including live smoke, finalization audit, drop `gate.sh`, mark PR ready only after evidence exists.

## Risks & Mitigations

- **Risk**: Live smoke is slow and flaky.  
  **Mitigation**: Use explicit timeouts, write every command transcript to the run directory, and keep `just ci` plus no-fallback tests separate from the live target.

- **Risk**: The script becomes another in-process runner in disguise.  
  **Mitigation**: Static tests forbid runner imports/calls and the host owns only node lifecycle/fixtures/assertions.

- **Risk**: Governance enactment requires a vote command that is not shipped.  
  **Mitigation**: Treat that as the core #161 finding. Fail with `missing-shipped-governance-vote` and do not merge until the parent scope is updated.

- **Risk**: Bash JSON parsing becomes fragile.  
  **Mitigation**: Add `jq` to the dev shell and use it for every JSON projection. Avoid `sed`/`awk` JSON parsing.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Smoke signs/submits transactions | #161 is explicitly the operator live proof | A build-only script would preserve the false-positive gap |
| Optional Haskell host | Reliable `withCardanoNode` lifecycle and deterministic genesis key export | Pure bash node lifecycle would duplicate fragile node readiness/patched genesis logic |
