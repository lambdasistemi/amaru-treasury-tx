# Data model — atomic OTC swap (issue #499)

## Wire record — `otcSwap` block of `intent.json`

| Field | Type | Required | Validation |
| --- | --- | --- | --- |
| `counterpartyAddress` | bech32 address | yes | parses; network matches the intent's network |
| `counterpartyTxIn` | `TxHash#Ix` | yes | resolvable; holds ≥ `incomingQuantity` of the named asset |
| `adaOutLovelace` | integer | yes | `> 0` |
| `incomingPolicy` | hex, 28 bytes | yes | `hex28` |
| `incomingAsset` | hex asset name | yes | `assetNameHex`; may be empty only if `incomingPolicy` is empty, which is rejected here |
| `incomingQuantity` | integer | yes | `> 0`; recorded positive, negated only at redeemer encoding |
| `statedPriceUsdPerAda` | decimal string | yes | `> 0`; operator-supplied, never derived |
| `fuelTxIn` | `TxHash#Ix` | yes | operator-controlled; pure ADA (INV-6) |

`incomingQuantity` is stored **positive**. The sign is a property of the
redeemer encoding, not of the operator's intent. This keeps the JSON
schema free of negative-number rules and keeps the archive readable.

The scope block, wallet block, signers, validity bound and rationale
reuse the existing shared shapes unchanged.

## Typed payload — `OtcSwapPayload`

| Field | Type | Meaning |
| --- | --- | --- |
| `ospCounterpartyAddress` | `Addr` | destination of the ADA leg |
| `ospCounterpartyUtxo` | `TxIn` | supplies the incoming asset |
| `ospCounterpartyLeftover` | `MultiAsset` | asset remainder returned to the counterparty |
| `ospCounterpartyLovelace` | `Coin` | lovelace on the counterparty output: ADA leg plus their input's own lovelace |
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
- **INV-4 — counterparty conservation.** The counterparty's output
  carries their input's lovelace plus `adaOut`, and their asset
  holding less exactly `incomingQuantity`.
- **INV-5 — the counterparty is never charged.** The fee is drawn from
  the operator's fuel UTxO. The counterparty's lovelace delta equals
  `+adaOut` exactly, with no fee subtracted (FR-004a).
- **INV-6 — collateral is pure ADA and operator-owned.** The collateral
  input carries no native assets and is not the counterparty's, so the
  collateral return carries no native assets (FR-004b).
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
