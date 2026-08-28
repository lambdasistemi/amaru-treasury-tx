# Plan — atomic OTC swap (issue #499)

## Evidence this shape is reachable

Three transactions pin the target.

| Source | Scope | Legs | Built by |
| --- | --- | --- | --- |
| `9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1` | `ops_and_use_cases` | −47.619047 ADA / +10 USDM | SundaeSwap offchain |
| unsubmitted draft | `core_development` | −50 ADA / +10 iUSD | SundaeSwap offchain |
| `1941f38f92311138ed5d70d830b375f89a42f9155205966d0a73ce58936cd4d4` | `network_compliance` | −47.619047 ADA / +10 USDM | `cardano-cli`, by hand, 2026-08-28 |

The third was assembled from this repository's own metadata and the
live node, inspected, and phase-1 validated. It is the executable
reference for this feature: the tool must reproduce that shape from an
intent.

## Constraints the validator imposes

From `treasury-contracts/lib/logic/treasury/disburse.ak`:

- `equal_plus_min_ada(merge(input_sum, negate(amount)), output_sum)`,
  where both sums range **only** over UTxOs whose payment credential is
  the treasury script. A negative entry in `amount` therefore obliges
  the continuing output to carry that much more of the asset.
- Non-zero outgoing lovelace requires the validity interval to be
  entirely before the configured expiration.
- `satisfied(permissions.disburse, extra_signatories, …)` governs the
  multisig. The counterparty is outside this check.

## What already exists

The redeemer encoder is already the right shape. `disburseUsdmRedeemer`
in `lib/Amaru/Treasury/Redeemer.hs` emits
`Constr 3 [Map [(B "", Map [(B "", I lovelace)]), (B policy, Map [(B asset, I qty)])]]`,
and `I` is unconstrained in sign. `payTo` in the `Cardano.Tx.Build` DSL
already accepts a full `MaryValue`. Fee convergence, ExUnits,
`script_data_hash`, collateral and min-ADA remain the DSL's
responsibility and are not reimplemented.

## What blocks it

1. `IntentJSON/Schema.hs` types disburse amounts with
   `positiveIntegerSchema` (`minimum: 1`). `just schema-check` runs in
   `just ci`, so a negative leg cannot be smuggled into the existing
   block. Addressed by FR-010: a separate `otc-swap` schema.
2. Wallet selection borrows `selectWallet` from the swap wizard, which
   chooses pure-ADA fuel. The swap needs a counterparty UTxO carrying
   the incoming asset.
3. `DisburseAnswers` validation rejects non-positive amounts
   unconditionally, and `DisburseDestination` cannot express an
   incoming leg.
4. `RedeemerSpec.hs` pins redeemer CBOR by hex; new cases need pinned
   vectors of their own.
5. `UsdmDisburseGoldenSpec.hs` is a `pendingWith` stub, so there is no
   golden harness to copy for a multi-asset treasury build.
6. The witness flow assumes every signer is a vault identity. The
   counterparty is external.

## Strategy

Add `otc-swap` as a sibling action rather than widening `disburse`.
The existing disburse path — live on mainnet — is not modified. The new
action owns its payload, schema block, translation, builder arm and
tests.

Asset identity moves into the intent (FR-007). The existing
`Constants.hs` USDM singleton stays where it is, used by the existing
disburse path only.

## Live boundaries

- **Node.** Selection and build read pparams and UTxOs from a live
  node. Goldens run against a frozen `ChainContext` so they are
  deterministic; a separate live smoke exercises the real boundary.
- **Operator socket path.** `/code/cardano-mainnet/ipc/node.socket` is
  dead on the current host; the live socket is
  `/srv/prod-hot/cardano/mainnet/ipc/node.socket`. This silently broke
  `tx-validate` and `tx-inspect` during investigation. Fixing the
  operator documentation is tracked separately and is not this
  ticket's code.

## Slices

Each slice is bisect-safe and independently reviewable.

**Slice A — redeemer and its vectors.** Expose a two-legged redeemer
encoder with a negative incoming entry. Pin its CBOR against the
redeemer bytes carried by the on-chain reference. No intent, no
builder, no CLI.

**Slice B — payload types and builder.** Add the `otc-swap` payload and
the `TxBuild` program: counterparty UTxO spent, four reference inputs,
withdraw-zero, treasury continuing output carrying leftover plus the
incoming asset, counterparty ADA output, required signers, validity
bound. Prove it against a frozen context reproducing the on-chain
reference body (AC-002).

**Slice C — intent JSON, schema, translation.** Add the action arm,
payload record, JSON codec, schema block, and translation to the typed
intent. Regenerate `docs/assets/intent-schema.json` so
`just schema-check` passes.

**Slice D — wizard and CLI.** Counterparty UTxO selection by asset
holding, treasury selection funding the ADA leg, price/quantity
validation (RJ-006), rationale construction, and the `otc-swap-wizard`
subcommand. Emits `intent.json`.

**Slice E — signing, reporting, docs.** Report both legs, the price,
the counterparty and the three signatures, distinguishing multisig from
UTxO-owner. Provide the counterparty handoff path (FR-012). Operator
docs, including the USDM-vs-iUSD risk statement (AC-006).

## Verification

Three tiers, in increasing strength:

1. **Bytes.** `just unit`, `just golden`, `just schema-check` per
   slice; full `just ci` before the PR is ready.
2. **Agreement with the chain (AC-002).** Reproducing the body of a
   transaction the validator already accepted is stronger than any
   assertion this repository writes about itself.
3. **Phase 2 on devnet (AC-005a, slice F).** The strongest available
   evidence, and the only tier that runs the validator. Tiers 1 and 2
   compare bytes; neither can show that the script *accepts* a negative
   leg. `scripts/smoke/devnet-local` already boots a node, deploys the
   contracts via `registry-init`, and submits real transactions in its
   `disburse-submit` phase; `MixedUtxoSmoke` already mints native
   assets onto treasury UTxOs. Slice F composes these.

Every tier carries a negative control, shown able to fail before it is
trusted. For tier 3 the control is decisive: a swap with a **positive**
incoming leg must be rejected on chain. Without it, a green submit
proves only that some transaction is valid, not that the sign
convention is what makes it so.

A live-boundary smoke against mainnet builds and runs `tx-validate`
only; it never submits, and stays out of `just ci` as a named operator
step.

## Risks

- **Wrong sign convention.** Mitigated by AC-002; a sign error cannot
  reproduce the reference bytes.
- **Counterparty UTxO spent between build and signature.** Inherent to
  the flow, not fixable here. The report must state the dependency so
  an operator sees it.
- **Stablecoin conflation.** USDM is fiat-backed; iUSD is not. The
  tool must never imply they are interchangeable, and must not default
  the asset.
