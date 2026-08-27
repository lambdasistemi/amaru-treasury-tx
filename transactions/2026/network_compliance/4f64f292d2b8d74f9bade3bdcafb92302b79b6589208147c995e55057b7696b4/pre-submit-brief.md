# Independent pre-submit brief — Cyber Castellum invoice #3528

## Verdict

**Technical GO, limited to the recorded live-state snapshot and the
transaction's remaining validity window. This is not operator authorization.**
Submission still requires the operator's explicit approval and a final live
inspect/validation immediately before broadcast.

## Transaction and accounting

The signed mainnet disbursement has predicted txid
`4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4`.
Its intent and signed metadata identify **Invoice #3528 — CYBER CASTELLUM
CORPORATION**, August 2026, and pay **18,750 USDM** under policy
`c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad`, asset
`0014df105553444d`, to the Crypto Accounting Group address
`addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`.

Seven spending inputs are present: six treasury inputs totalling
18,998.542293 USDM and 139.235155 ADA, plus one 9.755740-ADA wallet input.
Outputs are 248.542293 USDM + 138.045595 ADA back to treasury, 18,750 USDM
+ 1.189560 ADA to the beneficiary, and 8.780008 ADA wallet change. With the
0.975732-ADA fee, both ADA and USDM conserve exactly. The 1.463598-ADA total
collateral is the failure path, not an additional successful spend.

The live wallet query totals 91.275794 ADA. Replacing its selected 9.755740
ADA input with 8.780008 ADA change gives 90.300062 ADA: the 0.975732 ADA
difference is exactly the fee, so there is no unexplained wallet discrepancy.

## All treasury UTxOs

Both live treasury reports agree entry-for-entry on 18 UTxOs and totals of
19,019.421791 USDM and 611,069.353175 ADA. The six selected, live UTxOs are
`0abab118…#0`, `968fd01e…#0`, `a5003a71…#1`, `a80f4466…#1`,
`affe90d1…#0`, and `e9525199…#1`. Two unselected USDM UTxOs,
`cda0126e…#1` and `cda0126e…#2`, retain 20.879498 USDM. The ten unselected
ADA-only UTxOs are `1defcad5…#0`, `282bebe2…#0`, `44454ed0…#1`,
`455310f3…#0`, `57faba5b…#8`, `bbc15f8a…#0`, `c4bb8f0a…#0`,
`c68daf5d…#0`, `db651691…#0`, and `eef03312…#0`. Thus post-success total
treasury USDM is 269.421791, including the two untouched small UTxOs; no
treasury UTxO is unclassified.

## Signers, live state, validity, and precedent

The signed body requires the network-compliance owner
`8bd03209…fb1c1` and extra owner `f3ab64b0…23e2e`; exactly two vkey
witnesses are present. The recorded live `tx-validate` exited 0, reports
`structurally_clean`, obtains every spending/reference input, protocol
parameters, rewards and slot from N2C, and has witness completeness 0. The
later live UTxO snapshots still contain every selected input. The signed and
unsigned bodies have an empty diff, and the envelope's CBOR equals
`signed-tx.hex`.

At recorded tip 196251545, upper bound 196296876 left 45,331 slots
(about 12h35m; estimated expiry 2026-08-27 20:39:27Z). This GO expires with
that bound or any intervening input spend.

Label-filtered history finds exactly prior invoices #3508, #3516 and #3522.
Their signed-body diffs change only chain-state/accounting fields; payee,
18,750-USDM amount, asset, signer roster, references and scripts/redeemers are
unchanged. The intent matrix confirms four unique invoice CIDs and #3528's
distinct August description, justification and cycle-review evidence. The
released diff tool version is 0.2.3.0; the Amaru CLI version is not recorded
in the supplied artifacts, a provenance omission but not a transaction-validity
failure.
