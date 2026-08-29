# Tasks — atomic OTC swap (issue #499)

Task IDs are stable. A slice is complete only when every task in it is
checked and the slice gate is green.

## Slice A — redeemer and vectors

- [x] **T-A01** Add `otcSwapRedeemer` to `Amaru.Treasury.Redeemer`,
      negating the incoming quantity at encoding (INV-1).
- [x] **T-A02** Pin its CBOR in `RedeemerSpec.hs` against the redeemer
      bytes carried by on-chain `9ed505b4…`, decoded from the archived
      transaction rather than from this repository's own output.
- [x] **T-A03** Negative control: a positive incoming entry must fail
      T-A02, demonstrated before the vector is trusted.
- [x] **T-A04** Confirm existing `disburseAdaRedeemer` /
      `disburseUsdmRedeemer` vectors are byte-unchanged.
- [x] **T-A05** Property: `otcSwapRedeemer p a q l === disburseUsdmRedeemer p a (negate q) l`
      over generated policies, asset names (incl. empty), and
      magnitudes. From audit finding F1 (submission 1): the shipped
      vectors pin one 4-tuple, so a constant encoder passes them.
- [x] **T-A06** Structural assertion on generated input: ADA leg `I l`,
      asset leg `I (negate q)` strictly negative, ADA map-key first
      (key order is load-bearing for byte identity).
- [x] **T-A07** Include `otcSwapRedeemer` in the `roundTrip` CBOR check.
- [x] **T-A08** Keep the single-vector chain pin; the property is added
      beside it, never instead of it.

## Slice B — payload and builder

- [x] **T-B01** Add `OtcSwapPayload` / `OtcSwapIntent` in
      `Amaru.Treasury.Tx.OtcSwap`.
- [x] **T-B02** Implement `otcSwapProgram`.
- [x] **T-B03** Implement `runOtcSwapAction` in
      `Amaru.Treasury.Build.OtcSwap`.
- [x] **T-B04** Golden: rebuild the body of on-chain `9ed505b4…` from a
      frozen `ChainContext` and assert byte equality (AC-002).
- [x] **T-B05** Fixture set for T-B04 — intent, pparams, utxos,
      exunits, provenance note recording the mainnet txid and its
      block.
- [x] **T-B06** Assert INV-2, INV-3, INV-4 on the built body.
- [x] **T-B07** Builder-only properties, on an operator-funded
      fixture: collateral input is exactly `difWalletUtxo`, and the
      counterparty output carries their lovelace + adaOut with no fee
      deducted. INV-6 ownership/purity is slice D (T-D02) - the
      builder cannot know either, and the reference tx is
      counterparty-funded.
- [x] **T-B08** Assert INV-7: `requiredSigners` excludes the
      counterparty and holds two distinct scope owners.
- [x] **T-B09** Negative controls for T-B06..T-B08, each shown able to
      fail.
- [x] **T-B10** Assert `scriptIntegrityHash` equals the reference's.
      From audit finding T-B04-complete: it is the only body field
      recording the redeemer, so without it an ADA-only Disburse or a
      dropped negate still passes.
- [x] **T-B11** Assert output identity `(address, datum, value)`, not
      only coin/value.
- [x] **T-B12** One builder-calling negative control per omitted field.
- [x] **T-B13** State the completeness rule in the haddock and name the
      acknowledged encoding artifacts, so a reader can tell an
      exclusion from an omission.

## Slice B2 — address-targeted counterparty selection

Opened 2026-08-29 by a ticket-owner scope change that landed after
slice B was dispatched: the wizard targets a counterparty ADDRESS and
may need several UTxOs when a balance is fragmented (FR-008a/FR-008b).
Slice B built `ospCounterpartyUtxo :: TxIn`, singular, which was
correct against its mandate as written. Not a defect; a forward slice.

- [ ] **T-B2-01** `ospCounterpartyUtxos :: NonEmpty TxIn`; spend all of
      them.
- [ ] **T-B2-02** Counterparty output carries their COMBINED remainder
      and COMBINED input lovelace plus `adaOut` (FR-008b).
- [ ] **T-B2-03** Restate INV-4 in the golden as a sum over all
      counterparty inputs. The single-input reference cannot exercise
      this, so a second fixture with a fragmented balance is required —
      otherwise the assertion is untested for the case it exists for.
- [ ] **T-B2-04** Negative control: a build that drops one of several
      counterparty inputs must fail the conservation assertion.

## Slice C — intent JSON, schema, translation

- [x] **T-C01** `OtcSwap` on `Action`, its singleton, and the type-family
      instances.
- [x] **T-C02** `OtcSwapInputs` with codec; quantity stored positive.
- [x] **T-C03** `translateOtcSwap`.
- [x] **T-C04** `otcSwapSchema`; regenerate
      `docs/assets/intent-schema.json` so `just schema-check` passes.
- [x] **T-C05** Assert `disburseSchema` bytes are unchanged (FR-010).
- [x] **T-C06** Round-trip property: encode/decode is identity.
- [x] **T-C07** Assert INV-10 determinism: same intent, same bytes,
      twice.
- [x] **T-C08** Reject an unknown action and a malformed asset id.

## Slice D — wizard and CLI

- [x] **T-D01** `selectCounterpartyUtxos` — select from the counterparty
      ADDRESS, returning one or more UTxOs whose combined holding meets
      the incoming quantity. Prefer fewest inputs, then smallest total.
      `--counterparty-txin` is an optional repeatable restrict, mirroring
      `disburse-wizard --treasury-txin`; a shortfall within a restricted
      set is an error, not a widening (FR-008a).
- [x] **T-D02** `selectFuelUtxo`, pure-ADA only (INV-6).
- [x] **T-D03** `selectTreasuryForAdaOut`, preserving all native assets
      (INV-3).
- [x] **T-D04a** Enforce RJ-001 for the incoming leg: reject
      `incomingQuantity <= 0` in the wizard. Ratified from auditor
      candidate invariant CINV-nonpositive-qty (slice A, submission 1):
      `negate 0 = 0` is not strictly negative and a negative input
      double-flips, so INV-1 depends on this guard existing here. The
      encoder stays total by design.
- [x] **T-D04** `checkStatedPrice` with a declared tolerance (INV-9).
- [x] **T-D05** `otcSwapToTreasuryIntent`.
- [x] **T-D06** `otc-swap-wizard` parser and runner; register the
      subcommand.
- [x] **T-D07** Rejection tests for RJ-001..RJ-006, each with a
      negative control.
- [x] **T-D08** Wizard golden: fixed env plus answers produce a fixed
      intent.
- [x] **T-D09** Determinism control invokes the encoder TWICE and
      compares the two results. From audit finding T-D08: a single
      binding compared to itself cannot fail.
- [x] **T-D10** Sweep the golden spec for the same `x `shouldBe` x`
      shape; state explicitly if none remain.

## Slice E — reporting, signing, docs

- [ ] **T-E01** Report both legs, the stated price, and the
      counterparty.
- [ ] **T-E02** Report the signature roster split into multisig
      participants and ledger-level UTxO owners (INV-7).
- [ ] **T-E03** Report the counterparty-UTxO dependency, so an operator
      sees that spending it invalidates the transaction.
- [ ] **T-E04** Counterparty handoff path for an external signer with
      no vault identity (FR-012).
- [ ] **T-E04a** A check that reports whether a pending transaction's
      inputs are still unspent, so the operator learns a swap is dead
      before chasing signatures. Ruled 2026-08-29: detect, do NOT
      auto-rebuild - re-selecting a UTxO silently changes what signers
      already approved, and the terms may need renegotiating.
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
