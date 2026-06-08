# Plan — Multi-destination contingency disburse (#326)

## Tech stack

Haskell (GHC 9.6), `cardano-tx-tools` `TxBuild` DSL,
`cardano-ledger-conway`, `plutus-tx` Data redeemers, `aeson` intent
JSON, Hspec + golden CBOR + QuickCheck, `optparse-applicative` CLI.
Build/test via the Nix shell + `just`.

## Design decision: generalize, don't fork

The single-beneficiary assumption lives in the typed disburse intent
(`DisburseAnswers`, `ResolverInput`, `DisburseEnv`, `DisburseAdaPayload`,
the intent JSON), the resolver, and `disburseAdaProgram`. We **lift the
ADA path to a non-empty list of beneficiary outputs** rather than adding
a parallel contingency-only program. N=1 is the existing behavior and
must stay byte-identical (guarded by unchanged single-destination
goldens). USDM stays single-beneficiary (explicitly out of scope).

Output ordering is fixed and deterministic: **treasury leftover first
(output 0), then beneficiaries in operator order**. This preserves the
USDM `peek (observeTxOutCoin 1)` assumption for the untouched USDM path
and keeps the N=1 ADA CBOR identical.

## Slices (one bisect-safe commit each)

### Slice A — Typed ADA intent + tx-build carry a destination list
Lift the typed ADA disburse model to a non-empty list of beneficiary
outputs and loop `payTo` in `disburseAdaProgram`; redeemer `amount` = Σ;
leftover = input − Σ. Update the single translation/build site and the
intent JSON schema. Every existing single-destination caller passes a
singleton; existing single-destination goldens stay byte-identical; add
a 2-destination golden.
- Files: `lib/Amaru/Treasury/Tx/Disburse.hs`,
  `lib/Amaru/Treasury/Tx/DisburseWizard.hs` (DisburseAdaPayload / the
  ADA arm of `disburseToTreasuryIntent` + `resolveDisburseEnvIC` ADA
  arm), intent JSON schema module + `test/golden`, `test/unit` disburse
  specs.
- Proof: golden CBOR (N=1 unchanged + new N=2), unit tests on Σ/leftover.

### Slice B — `contingency-disburse-wizard` repeatable destinations
Replace the single `--destination-scope`/`--ada-amount` pair with a
repeatable `--to <scope>:<ada>` flag in `ContingencyDisburseOpts` +
parser; `runContingencyDisburse` resolves each destination scope's
address from verified metadata and builds the beneficiary list; reject
`Contingency` destination and empty set. Verify scopes set = Contingency
∪ destinations.
- Files: `lib/Amaru/Treasury/Cli/DisburseWizard.hs`, parser unit spec
  under `test/unit/Amaru/Treasury/Cli/`.
- Proof: parser unit tests (repeat flag, reject Contingency, reject
  empty, scope:ada parse errors).

### Slice C — Devnet 2-destination proof (Option B′)
Prove on a live devnet that the real Sundae treasury + permissions
validators accept a single disburse with 2 beneficiary outputs. The
contingency wizard can't run on devnet (only `core_development` is
registered; `verifyRegistry` aborts pre-submission for unregistered
scopes — `Registry/Verify.hs:214-220`; registering Contingency is
disproportionate). Vehicle B′:
1. `disburse-wizard --scope core_development` → real single-dest intent.
2. `jq`-rewrite to slice-A's 2-destination `destinations` array; set
   `treasuryLeftoverLovelace = input − Σ`; bump treasury funding for
   2 ≥min-UTxO outputs.
3. `build_sign_submit` on the live devnet → real 2-output tx.
4. Assert 4 outputs [leftover, destA, destB, walletChange], redeemer =
   Σ, leftover = input − Σ, ACCEPTED on-chain; record the txid.
- Files: `scripts/smoke/smoke.sh` (new multi-dest disburse phase), smoke
  helpers; projection unit tests as needed; cabal if wiring changes.
- Proof: the smoke phase submits + asserts on the live devnet.
- Honesty: the smoke + commit document that this proves the on-chain
  N>1 output shape via the core_development treasury; the contingency
  CLI/scope-resolution is covered by slice-B unit tests.

## Risk notes

- **N=1 byte-identity** is the key regression guard — if a
  single-destination golden changes, the generalization broke ordering
  or value math. Treat any single-destination golden diff as a failure
  to investigate, not to accept.
- USDM path (`disburseUsdmProgram`) is untouched and still
  single-beneficiary; do not regress its `observeTxOutCoin 1` peek.
- Min-UTxO per beneficiary output: each beneficiary must satisfy
  protocol min-ADA; the resolver's shortfall math must sum across
  destinations.
