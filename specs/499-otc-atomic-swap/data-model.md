# Data model — atomic OTC swap (issue #499)

## Wire record — `otcSwap` block of `intent.json`

| Field | Type | Required | Validation |
| --- | --- | --- | --- |
| `counterpartyAddress` | bech32 address | yes | parses; network matches the intent's network |
| `counterpartyTxIn`&nbsp;→&nbsp;`counterpartyTxIns` | see below | yes | staged: singular until slice B2, then an array |
| `adaOutLovelace` | integer | yes | `> 0` |
| `incomingPolicy` | hex, 28 bytes | yes | `hex28` |
| `incomingAsset` | hex asset name | yes | `assetNameHex`; may be empty only if `incomingPolicy` is empty, which is rejected here |
| `incomingQuantity` | integer | yes | `> 0`; recorded positive, negated only at redeemer encoding |
| `statedPriceUsdPerAda` | decimal string | yes | `> 0`; operator-supplied, never derived |
| `fuelTxIn` | `TxHash#Ix` | yes | operator-controlled; pure ADA (INV-6) |

`incomingQuantity` is stored **positive**. The sign is a property of the
redeemer encoding, not of the operator's intent. This keeps the JSON
schema free of negative-number rules and keeps the archive readable.

### The counterparty field is staged across two slices

Target shape (FR-008a): `counterpartyTxIns`, a **non-empty array** —
each outref resolvable and at `counterpartyAddress`, with a
**combined** holding ≥ `incomingQuantity`. A fragmented balance is
ordinary and one UTxO need not cover the trade.

Shipped shape until slice B2 lands: `counterpartyTxIn`, a **single**
`TxHash#Ix`, mirroring `OtcSwapPayload`'s `ospCounterpartyUtxo :: TxIn`.

This is deliberate staging, not drift. The address-targeting ruling
arrived after slice B was dispatched, so slice B built the singular
payload correctly against its mandate; slice C mirrors that payload
rather than inventing a wire shape the builder cannot consume. **B2
changes the payload, the JSON, and the golden together**, which keeps
each commit bisect-safe.

An auditor should read a singular field here as conforming, not as a
defect, until B2 is merged.

### Entry units versus recorded units

FR-007a/FR-007b govern what an operator **types** — `--incoming 10
--incoming-asset usdm`, `--ada-out 47.619047`. This wire record stores
the **resolved** values: policy and asset as hex, amounts in base
units. The CLI resolves and converts; the intent is a machine record
and an audit artifact, so it stays unambiguous. The two are not in
conflict.

The scope block, wallet block, signers, validity bound and rationale
reuse the existing shared shapes unchanged.

## Typed payload — `OtcSwapPayload`

| Field | Type | Meaning |
| --- | --- | --- |
| `ospCounterpartyAddress` | `Addr` | destination of the ADA leg |
| `ospCounterpartyUtxos` | `NonEmpty TxIn` | supply the incoming asset. Several is ordinary: a counterparty balance is often fragmented (FR-008a) |
| `ospCounterpartyLeftover` | `MultiAsset` | **combined** asset remainder across those inputs, returned on one output (FR-008b) |
| `ospCounterpartyLovelace` | `Coin` | lovelace on the counterparty output: ADA leg plus the **summed** lovelace of their inputs |
| `ospAdaOut` | `Coin` | ADA leaving the treasury |
| `ospIncomingPolicy` | `PolicyID` | incoming asset policy |
| `ospIncomingAsset` | `AssetName` | incoming asset name |
| `ospIncomingQuantity` | `Integer` | positive quantity entering the treasury |
| `ospLeftoverLovelace` | `Coin` | ADA retained on the treasury continuing output |
| `ospLeftoverAssets` | `MultiAsset` | treasury's pre-existing assets, preserved |

The fuel/collateral UTxO and the treasury UTxO list live in the shared
intent fields, alongside the four reference inputs and the signer
roster, exactly as the disburse path carries them.

## Invariants

- **INV-1 — redeemer mirrors the legs.** The encoded redeemer is
  `Constr 3 [Map [(B "", Map [(B "", I adaOut)]), (B policy, Map [(B asset, I (negate qty))])]]`.
  The ADA entry is positive; the asset entry is strictly negative.
- **INV-2 — treasury conservation.** Over treasury-addressed UTxOs,
  `output = input − adaOut + incomingQuantity`, satisfying the
  validator's `equal_plus_min_ada(merge(input_sum, negate(amount)), output_sum)`.
- **INV-3 — assets preserved.** Every native asset on the selected
  treasury inputs appears on the continuing output, in full. The swap
  adds the incoming asset; it removes nothing.
- **INV-4 — counterparty conservation.** Summed over **all** their
  spent inputs, the counterparty's single output carries their total
  input lovelace plus `adaOut`, and their total asset holding less
  exactly `incomingQuantity`. Stated as a sum because the incoming
  asset may be drawn from several UTxOs (FR-008a); a per-input reading
  is wrong the moment more than one is spent.
- **INV-5 — the counterparty is never charged.** The fee is drawn from
  the operator's fuel UTxO. The counterparty's lovelace delta equals
  `+adaOut` exactly, with no fee subtracted (FR-004a).
- **INV-6 — collateral is pure ADA and operator-owned.** The collateral
  input carries no native assets and is not the counterparty's, so the
  collateral return carries no native assets (FR-004b).

  *Enforced in slice D (`selectFuelUtxo`, T-D02), not in the builder.*
  The builder is agnostic about who funds: it uses whatever fuel UTxO
  and change address it is handed, and cannot know their ownership.
  This matters because the on-chain reference `9ed505b4…` is
  **counterparty-funded** — its collateral `c17a1d53…#1` sits at the
  counterparty's address — so a builder that hard-enforced INV-6 could
  never reproduce a body the validator accepted. INV-5 likewise holds
  only when the change address is the operator's.
- **INV-7 — signer split.** `requiredSigners` contains the scope owner
  and at least one other scope owner, and never the counterparty. The
  counterparty's witness is required by the ledger because their UTxO
  is spent; that is not a multisig membership claim.
- **INV-8 — expiry.** `invalidHereafter` is strictly before the
  treasury's configured expiration, which the validator demands
  whenever non-zero lovelace leaves the treasury.
- **INV-9 — price agreement.** `incomingQuantity / adaOut` equals
  `statedPriceUsdPerAda` within a declared tolerance. Disagreement is
  RJ-006 and fails the build; the stated value is what is recorded and
  rendered.
- **INV-10 — determinism.** The same intent produces identical bytes.

Each invariant is asserted in tests and each assertion is shown able to
fail before it is trusted.

## State

The intent is immutable once written. There is no in-flight state
machine: an intent either builds or is rejected. The counterparty UTxO
is a chain dependency outside this tool's control — if it is spent
before signatures are gathered, the build is dead and a fresh intent is
required. The report states this dependency so an operator sees it
before circulating the transaction.
