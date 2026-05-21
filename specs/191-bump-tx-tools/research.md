# Research: bump cardano-tx-tools reward-state validation

## Decision: pin `cardano-tx-tools` to commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`

**Rationale**: `v0.2.0.0` is the target release for #191, but the
release is an annotated tag. GitHub reports annotated tag object
`d53943d842b740b313b6b67c7784f4308e5847f0` pointing to commit
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`. Cabal
`source-repository-package tag:` must use a commit-ish accepted by git
checkout; the issue owner clarified that the commit SHA is the required
value.

The selected commit is a strict descendant of upstream PR #62's merge
commit `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`:
`gh api repos/lambdasistemi/cardano-tx-tools/compare/6a7a7d424594e8d891dd2b7df5c4e9a7884e6779...9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`
reports `ahead_by = 14`, `behind_by = 0`, `status = ahead`.

**Alternatives considered**:

- Keep current pin `25d7ce349f826e9888fb8565eeb816babb06d922`:
  rejected because it is pre-fix and preserves the downstream skips.
- Pin PR #62 merge commit `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`:
  rejected because the issue recommends the latest release and A-001
  approves `v0.2.0.0`'s commit object.
- Use annotated tag object
  `d53943d842b740b313b6b67c7784f4308e5847f0`: rejected for
  `cabal.project tag:` because it is not the release commit.

## Decision: regenerate the fixed-output hash in the same slice as the pin

**Rationale**: The existing `--sha256`
`1nhds5ihs1ywi7sl6i27q6zlphcmi5wiqgdhlbvhp0s1p170jjgm` belongs to the
old commit. `cabal.project` source-repository-package pins are
Nix-fetched as fixed-output sources, so a tag/hash mismatch either
fails the fetch or makes the dependency update unreproducible.

The implementation slice must use the repository's Cardano dependency
workflow: prefetch the exact commit, convert the resulting SRI to nix32
when necessary, update `--sha256`, and prove the fetch with Nix before
acceptance.

**Alternatives considered**:

- Let Cabal fetch by tag and leave `--sha256` stale: rejected because
  Nix checks would fail and reviewers could not reproduce the source.
- Regenerate hash in a later cleanup commit: rejected because the
  intermediate commit would be unbuildable and not bisect-safe.

## Decision: remove the withdrawal short-circuit from `validateFinalPhase1`

**Rationale**: The old skip in
`lib/Amaru/Treasury/Build/Common.hs` returned `Right ()` for any
transaction body with withdrawals. That workaround was only justified by
the old tx-tools validator lacking reward-account state. After the bump,
withdrawal-bearing final transactions should run the same Phase-1
pre-flight as all other built transactions.

The helper must keep its existing witness-completeness filter: unsigned
final transactions can legitimately lack vkey witnesses at build time,
and those failures are signing-step noise. All other ledger failures
remain structural and must reject the build result.

**Alternatives considered**:

- Keep a narrower withdrawal skip for all withdrawal transactions:
  rejected because it would fail FR-003 and leave the primary workaround
  in place.
- Remove witness-completeness filtering too: rejected because signing
  still happens after build, so unsigned transaction witness failures are
  expected at this seam.

## Decision: reassess governance-withdrawal-init before deciding removal

**Rationale**: `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
has a separate `materializeResultSkipPhase1` path currently used by the
proposal arm, and the materialization arm is affected by the shared
withdrawal skip. The bump may make the materialization path pass normal
validation, but the proposal path may still depend on a separate ledger
rule such as `TreasuryWithdrawalReturnAccountsDoNotExist` or a
deposit-sensitive rule tracked upstream.

Implementation must run the existing proposal and materialization
fixtures against the bumped validator. The result decides the code path:
remove the skip if fixtures pass; otherwise retain only a named residual
skip and stop for parent-owner clarification before widening scope.

**Alternatives considered**:

- Delete `materializeResultSkipPhase1` unconditionally: rejected because
  proposal validation may still need reward/return-account state not
  represented by the frozen `ChainContext`.
- Keep the skip with the old comment unconditionally: rejected because it
  leaves stale rationale after the tx-tools reward-state fix.

## Decision: no live-chain smoke for #191

**Rationale**: The ticket changes dependency resolution and offline
validation behavior, not an operator command or live submission flow.
Frozen `ChainContext` fixtures exercise the relevant boundary. `nix
flake check` and `./gate.sh` provide sufficient local/CI proof unless
the implementation discovers a new live-system dependency.

**Alternatives considered**:

- Run mainnet/preprod operator workflows: rejected by the spec non-goals
  and unavailable operator config.
- Add a DevNet smoke to `gate.sh`: rejected for this phase because no
  new live boundary is introduced; existing devnet checks remain under
  `just ci` where applicable.
