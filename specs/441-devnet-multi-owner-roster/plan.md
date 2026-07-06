# Implementation Plan: Devnet Multi-Owner Roster

## Scope

This ticket changes the devnet harness and its setup helpers only.
The swap builder in `lib/Amaru/Treasury/Tx/Swap.hs` and the
coordinator remain out of scope.

## Existing Context

- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` currently uses
  `genesisSignKey` for funding, owner signing, fuel, and collateral.
- The full smoke sets `fsiSigners = [genesisGuardKeyHash]` and
  selects fuel from `genesisAddr`.
- `RegistryInit` currently bakes one owner key hash into all four
  scope owner slots.
- `Cardano.Node.Client.E2E.Setup` already exports `mkSignKey`,
  `enterpriseAddr`, `keyHashFromSignKey`, and `addKeyWitness`.

## Design

Add a multi-owner devnet roster path while preserving the current
single-owner defaults for other devnet tests:

1. Introduce a small devnet owner-roster representation in
   `Amaru.Treasury.Devnet.RegistryInit` or adjacent devnet helper
   code, able to carry per-scope owner key hashes.
2. Keep existing `publishDevnetRegistryInit` behavior as the
   singleton-owner compatibility path.
3. Add an opt-in multi-owner publication path for the full-swap smoke
   so the on-chain scopes datum contains distinct owner hashes.
4. In `treasurySwapFullE2ESmoke`, derive deterministic owner and
   requester signing keys, write their cardano-cli signing-key JSON
   files under the run directory, and fund their enterprise
   addresses from genesis using the existing `payTo`/submit helper
   pattern.
5. Select the swap fuel/collateral UTxO from the requester address,
   build the existing `swapProgram` intent with the owner roster, and
   sign the resulting transaction with requester plus owner keys.
6. Extend the full-swap evidence/summary with enough roster metadata
   for #443 to locate the owner and requester key files.

## Slices

### Slice S1: Registry roster support

Add the opt-in multi-owner registry publication path and focused
tests or smoke assertions proving distinct scope owners are accepted.
Do not wire the full swap yet.

Owned files:

- `lib/Amaru/Treasury/Devnet/RegistryInit.hs`
- `lib/Amaru/Treasury/Devnet/Runner.hs` only if needed for a clean
  opt-in caller
- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- Existing devnet tests that must compile after the helper change

Focused proof:

- `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"`
  if a unit-level assertion is added.
- Otherwise `nix develop --quiet -c just build`.

### Slice S2: Full-swap multi-owner/requester wiring

Wire `treasury-swap-full-e2e` through the roster:

- deterministic owner and requester keys;
- funded owner and requester addresses;
- requester-owned `fsiWalletUtxo` and collateral;
- two owner `fsiSigners`;
- owner/requester key artifacts in the run directory;
- transaction signing with requester plus owner keys.

Owned files:

- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- `lib/Amaru/Treasury/Devnet/RegistryInit.hs` only for evidence
  projection helpers missed by S1
- `amaru-treasury-tx.cabal` only if a new devnet test module is added

Focused proof:

- `nix develop --quiet -c just devnet-smoke treasury-swap-full-e2e`

## Final Verification

- `./gate.sh`
- Focused devnet proof:
  `nix develop --quiet -c just devnet-smoke treasury-swap-full-e2e`
- GitHub PR checks green before marking ready.
