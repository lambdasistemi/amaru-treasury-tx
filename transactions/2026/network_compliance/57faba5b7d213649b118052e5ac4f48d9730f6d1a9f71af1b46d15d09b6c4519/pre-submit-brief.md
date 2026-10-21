# Pre-submit brief — network_compliance swap-40k-usdm (2026-08-05)

## 1. Summary

This transaction spends one `network_compliance` treasury UTxO
(610,923.506020 ADA) plus one small operator-wallet UTxO
(77.411622 ADA, used only for fee/collateral) to place **8 SundaeSwap
limit orders** selling a total of 209,424.083770 ADA for a minimum of
40,000 USDM (5,000 USDM floor per chunk), at a floor rate of
**0.191 USDM/ADA**, valid until slot 194526553 (~48h TTL). The
treasury change (401,473.182250 ADA) returns to the
`network_compliance` treasury address; wallet change (76.858483 ADA)
returns to the operator wallet. The tx requires two key witnesses —
`network_compliance` scope owner (`8bd03209…fb1c1`) and
`ops_and_use_cases` owner (`f3ab64b0…d23e2e`) — both present in
`signed-tx.tx`/`signed-tx.hex`.

## 2. Inputs/outputs ledger

| # | Item | Lovelace |
|---|---|---:|
| in | treasury UTxO `efff271a…#2` | 610,923,506,020 |
| in | wallet fuel UTxO `968fd01e…#2` | 77,411,622 |
| **in total** | | **611,000,917,642** |
| out 0–7 | 8× SundaeSwap order boxes (`addr1x8ax5k9…`) | 26,181,290,472 ×2 + 26,181,290,471 ×6 = 209,450,323,770 |
| out 8 | treasury change (`addr1xyezq8w…thzgk`) | 401,473,182,250 |
| out 9 | wallet change (`addr1qx9aqvs…sznjcrz`) | 76,858,483 |
| fee | | 553,139 |
| **out+fee** | | **611,000,917,642** |

**Conservation check: 611,000,917,642 = 611,000,917,642 — exact, no discrepancy.**
Only assets in play are lovelace (no non-ADA input tokens; treasury holds 0 USDM pre-tx per `treasuryLeftoverUsdm`). Wallet input funds fee+collateral entirely: `77,411,622 − 553,139 = 76,858,483` matches wallet change exactly. Collateral: input 77,411,622 − return 76,581,913 = 829,709 = `totalCollateral`, consistent. Note the wizard log records 10 treasury UTxOs totalling 611,069,353,175 lovelace, of which only this one (610,923,506,020) was consumed — the other ~145.8M lovelace across 9 UTxOs is untouched, unrelated to this tx.

## 3. Rate economics

Stated min rate: 0.191 USDM/ADA (`rateNumerator/rateDenominator = 191000/1000000`). Per-chunk: `chunkSizeLovelace` 26,178.010471 ADA gives datum floor-receive 5,000.000000 USDM (or 5,000.000001 for the two chunks absorbing the 2-lovelace remainder) — `5000 / 0.191 = 26178.010471…`, exact match. Aggregate: `209,424.083770 ADA × 0.191 = 40,000.000000 USDM`, exact. Each order's on-chain datum "give" amount equals `chunkSizeLovelace` (+1 for two chunks); the extra 3,280,000 lovelace/chunk sitting in the output value (SundaeSwap protocol fee 1,280,000 + ~2,000,000 order-box min-ADA/deposit) is *not* part of the swapped principal. This is internally consistent — the floor rate embedded in every datum matches the intent's stated min-rate to the lovelace/microUSDM.

## 4. Slippage / constant-product reasoning

**Not fully derivable from the provided artifacts.** `report.json` and the wizard/build logs carry no SundaeSwap pool reserve snapshot (ADA/USDM reserves, LP fee bps) at build time, so no constant-product price-impact model can be computed here — flagging rather than guessing. What *is* verifiable: this is a **limit order with an on-chain min-receive floor** (5,000 USDM/chunk), not a direct AMM swap, so downside is bounded by construction — the order can only fill at ≥0.191 USDM/ADA or sit unfilled/expire at TTL. Splitting into 8 chunks (~26.2k ADA each) is the operator's own slippage mitigation (smaller clips against the scooper), but its effectiveness against current pool depth cannot be assessed without a live pool-state read, which was explicitly out of scope for this brief.

## 5. Net deliverables

- USDM target arriving (post-fill, assuming full execution at floor): **40,000 USDM minimum**, to the SundaeSwap order address pending scooper settlement — not a direct treasury credit in this tx; a separate settlement path returns filled USDM (per the SundaeSwap datum's owner list, which embeds all four scope owners as settlement-eligible: core, ops, network_compliance, middleware).
- ADA consumed from treasury: 209,450,323,770 lovelace (209,450.32 ADA, principal + protocol fee/deposit overhead).
- Treasury change destination: `addr1xyezq8w…thzgk` (network_compliance treasury script address) — 401,473.182250 ADA.
- Wallet change destination: `addr1qx9aqvs…sznjcrz` (operator wallet) — 76.858483 ADA.

## 6. Risk checks

- **TTL**: `invalidHereafter` = 194526553, `invalidBefore` = null. Wizard computed this as "chain horizon +48h" at build time (09:54); no live tip slot is present in any provided file, so the slot-to-walltime mapping can't be independently re-derived here — this trusts the wizard's own horizon helper. build.log (09:54) and both witness timestamps (10:07, 11:01) are all well inside a 48h window, so no staleness concern from the build→sign gap itself.
- **Signer roster — flag resolved, not a live mismatch**: the archived directory's git history (`0bbc6dc9` → `64ad30a9` → `7b09d282` → `cc62c494`) shows the co-signer was briefly changed to `core_development` (`7095faf3…deffb`, commit `7b09d282`, along with a different TTL 194528562 and different wallet-change amount 76,858,476) and then explicitly reverted back to `ops_and_use_cases` (`f3ab64b0…d23e2e`) in commit `cc62c494`. **The current working tree (`summary.md`, `intent.json`, `report.json` as read) is at the reverted `cc62c494` state**, and it matches what's actually witnessed in `signed-tx.tx`/`answers/` (`8bd03209…` + `f3ab64b0…`) and what `tx-inspect`'s `requiredSigners` shows. No discrepancy in the artifacts as they stand today, but this is evidence of same-day churn on signer selection and TTL/change-output values — worth an explicit sanity glance before submit that no stale intermediate CBOR/witness pair from the `core_development` version gets mixed in.
- **Withdrawal-zero pattern**: tx includes a 0-lovelace withdrawal from `a64d1b9e…fc094` (the scope's `permissionsRewardAccount`) — standard Amaru "withdraw-zero" trick to invoke the permissions script for authorization, not a fund movement. No surprise there.
- No non-ADA assets move in this tx aside from the datum-encoded min-receive USDM references (which are not asset transfers, just order terms).

## 7. Provenance

- `tx-build`/wizard logs don't print an explicit `amaru-treasury-tx` CLI version string — a minor provenance gap. `validate-final.log` reports **tx-validate 0.2.0.0**.
- Predicted txid (from `report.json`, tool-computed, not independently re-hashed here): `57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519`.
- `inspect-final.log` (tx-inspect, Amaru rules): full tree resolves cleanly end to end — all inputs/reference-inputs/outputs/datums decode, `requiredSigners` = the two expected key hashes, no error/diagnostic entries present. Treated as **PASS**.
- `validate-final.log` (tx-validate, live node phase-1): `"structurally clean: 0 witness-completeness failures filtered"` — **PASS**, exit implied 0 per `build.log`'s own `VALIDATION OK`.
- `build.log` also independently confirms `re-evaluated 2 redeemers, 0 failed` and network-magic match (764824073, mainnet), matching `report.json.validation`.

## 8. Go/no-go

**GO.** Value conservation is exact to the lovelace across all inputs/outputs/fee; the rate math embedded in every SundaeSwap datum matches the stated 0.191 min-rate exactly; fee/collateral accounting is self-consistent; both independent verification passes (tx-inspect, tx-validate) are clean; and the two required signers on the actual signed body match the current (reverted, correct) archived summary — the earlier `core_development` co-signer variant is confirmed superseded, not live. The only open item is the absence of pool-depth data for a full slippage model, which is a known/acceptable gap given this is a floor-priced limit order (bounded downside by construction) rather than a direct AMM swap — not a blocker, but worth the operator's own eyeball on current SundaeSwap ADA/USDM pool depth before submitting, purely as a fill-probability/timing judgment call rather than a safety one.
