# Tasks — atomic OTC swap (issue #499)

Task IDs are stable. A slice is complete only when every task in it is
checked and the slice gate is green.

## Slice A — redeemer and vectors

- [ ] **T-A01** Add `otcSwapRedeemer` to `Amaru.Treasury.Redeemer`,
      negating the incoming quantity at encoding (INV-1).
- [ ] **T-A02** Pin its CBOR in `RedeemerSpec.hs` against the redeemer
      bytes carried by on-chain `9ed505b4…`, decoded from the archived
      transaction rather than from this repository's own output.
- [ ] **T-A03** Negative control: a positive incoming entry must fail
      T-A02, demonstrated before the vector is trusted.
- [ ] **T-A04** Confirm existing `disburseAdaRedeemer` /
      `disburseUsdmRedeemer` vectors are byte-unchanged.

## Slice B — payload and builder

- [ ] **T-B01** Add `OtcSwapPayload` / `OtcSwapIntent` in
      `Amaru.Treasury.Tx.OtcSwap`.
- [ ] **T-B02** Implement `otcSwapProgram`.
- [ ] **T-B03** Implement `runOtcSwapAction` in
      `Amaru.Treasury.Build.OtcSwap`.
- [ ] **T-B04** Golden: rebuild the body of on-chain `9ed505b4…` from a
      frozen `ChainContext` and assert byte equality (AC-002).
- [ ] **T-B05** Fixture set for T-B04 — intent, pparams, utxos,
      exunits, provenance note recording the mainnet txid and its
      block.
- [ ] **T-B06** Assert INV-2, INV-3, INV-4 on the built body.
- [ ] **T-B07** Assert INV-5 and INV-6: fee is drawn from the fuel
      UTxO, collateral input is pure ADA, collateral return has no
      native assets.
- [ ] **T-B08** Assert INV-7: `requiredSigners` excludes the
      counterparty and holds two distinct scope owners.
- [ ] **T-B09** Negative controls for T-B06..T-B08, each shown able to
      fail.

## Slice C — intent JSON, schema, translation

- [ ] **T-C01** `OtcSwap` on `Action`, its singleton, and the type-family
      instances.
- [ ] **T-C02** `OtcSwapInputs` with codec; quantity stored positive.
- [ ] **T-C03** `translateOtcSwap`.
- [ ] **T-C04** `otcSwapSchema`; regenerate
      `docs/assets/intent-schema.json` so `just schema-check` passes.
- [ ] **T-C05** Assert `disburseSchema` bytes are unchanged (FR-010).
- [ ] **T-C06** Round-trip property: encode/decode is identity.
- [ ] **T-C07** Assert INV-10 determinism: same intent, same bytes,
      twice.
- [ ] **T-C08** Reject an unknown action and a malformed asset id.

## Slice D — wizard and CLI

- [ ] **T-D01** `selectCounterpartyUtxo`, preferring the smallest
      sufficient holding.
- [ ] **T-D02** `selectFuelUtxo`, pure-ADA only (INV-6).
- [ ] **T-D03** `selectTreasuryForAdaOut`, preserving all native assets
      (INV-3).
- [ ] **T-D04** `checkStatedPrice` with a declared tolerance (INV-9).
- [ ] **T-D05** `otcSwapToTreasuryIntent`.
- [ ] **T-D06** `otc-swap-wizard` parser and runner; register the
      subcommand.
- [ ] **T-D07** Rejection tests for RJ-001..RJ-006, each with a
      negative control.
- [ ] **T-D08** Wizard golden: fixed env plus answers produce a fixed
      intent.

## Slice E — reporting, signing, docs

- [ ] **T-E01** Report both legs, the stated price, and the
      counterparty.
- [ ] **T-E02** Report the signature roster split into multisig
      participants and ledger-level UTxO owners (INV-7).
- [ ] **T-E03** Report the counterparty-UTxO dependency, so an operator
      sees that spending it invalidates the transaction.
- [ ] **T-E04** Counterparty handoff path for an external signer with
      no vault identity (FR-012).
- [ ] **T-E05** `docs/otc-swap.md`: end-to-end operator flow.
- [ ] **T-E06** State plainly that USDM and iUSD are different assets
      with different risk; no default asset (AC-006).
- [ ] **T-E07** Update `docs/architecture.md` module table and diagram.
- [ ] **T-E08** Operator skill reference for the new subcommand.

## Slice F — devnet submit (phase-2 proof)

The load-bearing slice. `scripts/smoke/devnet-local` already boots a
node, deploys the contracts via `registry-init`, and has a
`disburse-submit` phase that builds and submits. `MixedUtxoSmoke`
already mints a native asset onto treasury UTxOs. This slice composes
those two capabilities.

- [ ] **T-F01** Mint a test stablecoin on devnet and fund a
      counterparty wallet with it, reusing the `MixedUtxoSmoke` mint
      path.
- [ ] **T-F02** Add an `otc-swap-submit` phase to
      `scripts/smoke/devnet-local`, modelled on `disburse-submit`.
- [ ] **T-F03** Build, sign with all three keys, and submit the swap on
      devnet.
- [ ] **T-F04** Assert post-submission UTxO state: the treasury holds
      the incoming asset, the counterparty holds the ADA, and the
      treasury's pre-existing assets are intact (INV-2, INV-3, INV-4).
- [ ] **T-F05** Assert the operator paid the fee and posted the
      collateral, and that the counterparty's lovelace delta is exactly
      `+adaOut` (INV-5, INV-6).
- [ ] **T-F06** Negative control: the same swap with a **positive**
      incoming leg must be rejected by the validator. Without this,
      T-F03 passing proves only that some transaction submits, not that
      the sign convention is what makes it valid.
- [ ] **T-F07** Record the devnet txids and the phase output as
      evidence in the PR.

## Cross-cutting

- [ ] **T-X01** Live-boundary smoke: build against a real node and run
      `tx-validate` (AC-003). Named as an operator step, kept out of
      `just ci`.
- [ ] **T-X02** Full `just ci` green before the PR is marked ready.
- [ ] **T-X03** PR body updated to describe the shipped diff.

## Not this ticket

- Reverse direction (treasury sells a stablecoin for ADA).
- Extracting a shared preamble between the disburse and swap programs.
- Fixing the stale operator socket path
  (`/code/cardano-mainnet/ipc/node.socket`); tracked separately.
