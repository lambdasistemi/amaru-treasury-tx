# Spec — atomic OTC swap (issue #499)

## Problem

A treasury scope cannot acquire a stablecoin without selling ADA on a
public venue. An OTC swap settles both legs in one transaction: ADA
leaves the treasury to a counterparty, and the counterparty's
stablecoin enters the treasury, atomically. Either both happen or
neither does.

Two such transactions exist on mainnet. Neither was built by this
tool; both came from SundaeSwap's offchain library. A third was
assembled by hand with `cardano-cli` on 2026-08-28 to prove the shape
is reachable from this repository's data (see `plan.md`).

## User stories

**US-1 — build.** As a treasury operator I produce an unsigned OTC
swap for one scope: *N* units of a named stablecoin into the treasury,
*M* ADA out to a counterparty, at an operator-stated price, without
hand-writing CBOR or redeemer JSON.

**US-2 — review.** As a co-signer I read the built transaction and see
both legs, the price, the counterparty, and the rationale, before I
sign.

**US-3 — external signature.** As an operator I obtain the
counterparty's signature even though the counterparty is not a scope
owner and holds no vault identity here.

**US-4 — record.** As an auditor I read the archived intent and learn
what was traded, with whom, at what price, and on whose authority.

## Requirements

### Transaction shape

- **FR-001** The treasury spend carries a `Disburse` redeemer whose
  amount map has a positive ADA entry and a negative entry for the
  incoming asset.
- **FR-002** The treasury continuing output carries the scope's
  retained ADA, its pre-existing native assets, and the incoming
  asset quantity.
- **FR-003** Exactly one counterparty output carries the outgoing ADA.
- **FR-004** The counterparty supplies the incoming asset and nothing
  else. Their output carries the outgoing ADA plus any unspent
  remainder of the asset they contributed.
- **FR-004a** The treasury operator supplies the fee and the
  collateral, from an operator-controlled wallet UTxO. The
  counterparty never posts collateral and never bears the fee.

  *Rationale.* Collateral is forfeited when phase-2 fails, and phase-2
  here executes the treasury's own validator. Charging a counterparty
  for this repository's correctness is wrong, and it is an obstacle to
  every future OTC deal. A hand-built draft on 2026-08-28 inherited the
  opposite arrangement by copying the precedents, and placed the
  counterparty's entire 122,652.5 USDM in the collateral return.
- **FR-004b** The collateral input is pure ADA, so the collateral
  return carries no native assets.
- **FR-005** `requiredSigners` carries the scope owner and at least one
  other scope owner, and does **not** carry the counterparty.
- **FR-006** The transaction carries label-1694 rationale naming the
  event, label, description, justification, and destination.

### Inputs and identity

- **FR-007** The incoming asset is operator-supplied as policy id plus
  asset name. It is not a compile-time constant, and both USDM and
  iUSD are expressible.
- **FR-008** The counterparty address and the UTxO supplying the
  incoming asset are recorded in the intent.
- **FR-009** The intent records the operator-stated price and the two
  leg quantities as independent fields; price is never re-derived from
  a division at build time.

### Action identity

- **FR-010** The swap is a distinct top-level intent action,
  `otc-swap`. The existing `disburse` action, its JSON schema, and its
  on-chain behaviour are unchanged by this feature.

### Signing

- **FR-011** The tool reports all three required signatures — the two
  scope owners and the counterparty — distinguishing the multisig
  participants from the ledger-level UTxO owner.
- **FR-012** The counterparty's signature is obtainable without a vault
  identity for that key.

## Rejection behaviour

The build fails, with a named error and no partial artifact, when:

- **RJ-001** the incoming quantity is zero or negative, or the outgoing
  ADA is zero or negative;
- **RJ-002** the named counterparty UTxO does not hold at least the
  incoming quantity of the named asset;
- **RJ-003** the signer roster does not contain the scope owner plus at
  least one other owner;
- **RJ-004** the validity interval is not entirely before the
  treasury's configured expiration, which the validator requires
  whenever non-zero lovelace leaves the treasury;
- **RJ-005** the selected treasury UTxOs cannot fund the outgoing ADA
  while retaining min-ADA on the continuing output;
- **RJ-006** the stated price disagrees with the two leg quantities
  beyond a stated tolerance.

## Observable success

- **AC-001** An operator builds an unsigned OTC swap for a named scope
  from one command, given scope, counterparty, both leg quantities, the
  asset identity, and a rationale.
- **AC-002** Rebuilding from the archived intent of the on-chain
  reference `9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1`
  reproduces its transaction body, proving byte-level agreement with a
  transaction the validator accepted.
- **AC-003** `tx-validate` reports a freshly built swap structurally
  clean against a live node, with only witness-completeness
  outstanding.
- **AC-004** The rendered report states both legs, the price, the
  counterparty, and the three required signatures.
- **AC-005** Building the same intent twice produces identical bytes.
- **AC-005a** On a local devnet with the treasury contracts deployed
  and a minted test asset, an OTC swap is built, signed and
  **submitted**, and the resulting on-chain UTxO state shows the
  treasury holding the incoming asset and the counterparty holding the
  ADA.

  This is the only check that exercises **phase 2** — the validator
  actually accepting a `Disburse` redeemer with a negative leg. Golden
  tests compare bytes; they cannot demonstrate that the script runs.
  A negative control must show the phase failing when the sign is
  wrong.
- **AC-006** Operator documentation covers the flow end to end,
  including obtaining the counterparty signature, and states plainly
  that USDM and iUSD are different assets carrying different risk.

## Out of scope

- Any change to the on-chain validators.
- Price discovery or quoting; the price is operator-supplied, as in
  both precedents.
- The reverse direction (treasury sells a stablecoin for ADA). The
  data model must not preclude it; this slice does not ship it.
- Custody of counterparty keys.
