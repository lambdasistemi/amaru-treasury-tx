# Research: Local Devnet Smoke

## Decision 1: Use `cardano-node-clients:devnet`

**Decision**: Build the local smoke around the public
`cardano-node-clients:devnet` sublibrary pinned in `cabal.project`.
Use `Cardano.Node.Client.E2E.Devnet.withCardanoNode` and the
`Cardano.Node.Client.E2E.Setup` helpers rather than recreating a node
launcher.

**Rationale**: The dependency already ships the approved genesis files,
network magic, genesis signing key, and N2C readiness probe. Reusing it
keeps the local network aligned with the dependency line used by the
library and avoids hand-rolled process management.

**Alternatives considered**:

- Shell out to a custom `cardano-node` command: rejected because it
  duplicates readiness, cleanup, genesis patching, and socket probing.
- Use `cardano-testnet`: rejected because the repository does not
  currently expose that tool and the user explicitly selected
  `cardano-node-clients` devnet.

## Decision 2: Add a local-only `devnet` network alias

**Decision**: Introduce a documented local network name `devnet` for
smoke artifacts. It maps to network magic `42` and Cardano ledger
`Testnet` address/reward-account semantics.

**Rationale**: Existing wizard/build paths need a canonical intent
network name, not only a raw network magic. Today the supported public
names are `mainnet`, `preprod`, and `preview`; a devnet intent would
otherwise fail reward-account parsing, wizard network-family checks,
and socket magic lookup.

**Alternatives considered**:

- Pass only `--network-magic 42`: rejected because the intent JSON and
  reward-account code still require a recognized network string.
- Reuse `preview` with magic `42`: rejected because it would produce
  misleading artifacts and weaken network identity diagnostics.

## Decision 3: Use the pinned short epoch by default

**Decision**: Start with the pinned devnet genesis timing:
`epochLength = 500`, `slotLength = 0.1`, network magic `42`. The smoke
must report the effective epoch duration, approximately 50 seconds.
If implementation shows reward activation needs a tighter loop, add a
documented copied-genesis override rather than editing upstream files.

**Rationale**: The existing devnet is already short enough for a
manual withdrawal reward run, and preserving the pinned genesis lowers
the amount of custom local-network behavior to debug.

**Alternatives considered**:

- Patch the dependency genesis in place: rejected because it mutates a
  pinned external source and makes runs hard to reproduce.
- Always generate a fresh custom genesis: deferred until evidence
  shows the pinned 50-second epoch is too slow.

## Decision 4: Keep chain seeding separate from Amaru CLI behavior

**Decision**: Any local funding, delegation, reward-source setup,
registry anchors, or treasury UTxO preparation required by the smoke
is implemented as test harness setup. The release-facing Amaru CLI
continues to emit unsigned transactions only.

**Rationale**: The constitution forbids signing/submission in the
release CLI. A live devnet smoke needs chain state, but that need is
orthogonal to the operator command contract.

**Alternatives considered**:

- Add signer/submitter commands to `amaru-treasury-tx`: rejected by
  the build-never-sign-or-submit rule.
- Require the maintainer to hand-seed the chain every time: rejected
  because it makes the smoke non-repeatable and easy to misread.

## Decision 5: Deliver in three independently runnable phases

**Decision**: Implement `node`, `withdraw`, and `disburse` smoke phases
that can be selected independently before an `all` phase wires them
together.

**Rationale**: Node startup and network identity are prerequisites for
every later test. Positive withdrawal rewards are the riskiest unknown.
Disburse/build depends on local treasury anchors and can land after
the node and reward evidence is solid.

**Alternatives considered**:

- Build only a monolithic `all` smoke: rejected because failures would
  be harder to localize and the node boundary could be confused with
  treasury-state failures.

## Decision 6: Keep the devnet smoke opt-in

**Decision**: Add `just devnet-smoke` and a direct script entrypoint,
but do not include the live devnet smoke in `just ci`, release asset
builds, or default flake checks.

**Rationale**: The smoke starts a real node, waits for chain progress,
and can take minutes. It is release evidence, not the fast deterministic
CI gate.

**Alternatives considered**:

- Add it to `just ci`: rejected because it would make local and CI
  feedback slow and dependent on local process scheduling.

## Decision 7: Make `nix develop` self-contained for the smoke

**Decision**: Expose the required `cardano-node` binary through this
repository's development environment while continuing to consume the
devnet Haskell modules from the pinned `cardano-node-clients` source
repository package.

**Rationale**: The current Amaru dev shell does not provide
`cardano-node`. Requiring a sibling checkout of
`cardano-node-clients` would make the smoke depend on a local path
outside the repository.

**Alternatives considered**:

- Run tests from a separate `cardano-node-clients` dev shell: rejected
  because it complicates dependency resolution for the Amaru package.
- Ask maintainers to install `cardano-node` manually: rejected because
  it makes the quickstart less reproducible.
