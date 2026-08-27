# Cyber Castellum August 2026 disbursement

- **status:** submitted on mainnet; contract valid
- **txid:** `4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4`
- **block:** `b677010b191e7f1410d4a9a0f44f4fe8142b528a2f977bef8f49931a478b5c22`
- **block height:** 13,863,215
- **slot:** 196,272,442
- **block time:** 2026-08-27T13:52:13Z
- **scope:** `network_compliance`
- **event:** `disburse`
- **amount:** 18,750 USDM
- **beneficiary:** Crypto Accounting Group, the established Cyber Castellum payee
- **invoice:** Cyber Castellum invoice #3528, dated 2026-08-07, for the
  2026-07-01 through 2026-07-31 billing period (Milestone 4)
- **acceptance:** August 2026 cycle review, accepted 2026-08-07

## Intent and evidence

The transaction pays the same beneficiary address and amount as prior Cyber
Castellum invoices #3508, #3516, and #3522:

`addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`

The August transaction carries its own invoice label, description,
justification, invoice CID, and cycle-review evidence:

- `Invoice #3528 - Amaru.pdf`
  - IPFS: `ipfs://QmNQbjmE6B9JvqwrHX4JVnCepqGoVhDpGQuwaSUjwDeP9f`
  - SHA-256: `1cb3814924844626bb78dd2a08a2e88b21ebf1651ef5681a0d07681a199508a4`
- `2026_08_07_Amaru_Monthly_White_hacking.pdf`
  - IPFS: `ipfs://QmXGGFgD5vt1awuP3ttGgAwL4Rm2CYEuVgFkycgGwmi2xh`
  - SHA-256: `2f9d3b9cbc2356f0f16f42a699e5bba7e650c2c7fdafaab7743d627eb138a954`

Both documents were publicly retrieved and byte-verified against these
hashes. The three common contract and address-proof IPFS references were also
publicly retrieved.

## Transaction accounting

- Six treasury inputs: 18,998.542293 USDM and 139.235155 ADA.
- Wallet input/collateral:
  `1defcad59b4b67572d0bd6f82d98a35217261e2203bdca6179ff67b8d0ae3df2#1`,
  holding 9.755740 ADA.
- Beneficiary output: 18,750 USDM and 1.189560 ADA.
- Treasury change: 248.542293 USDM and 138.045595 ADA.
- Wallet change: 8.780008 ADA.
- Fee: 0.975732 ADA.
- Total collateral: 1.463598 ADA on the failure path.
- Validity upper bound: slot 196,296,876
  (2026-08-27T20:39:27Z).
- CIP-1694 auxiliary-data hash:
  `0d15de7b437dac89a1e67dbe368d5b98dd997fe62e32286224f734ed7dae8d5a`.

ADA and USDM conserve exactly. The ten unselected ADA-only treasury UTxOs and
two small USDM-bearing UTxOs remain untouched; post-success treasury holdings
are 269.421791 USDM plus the retained ADA reserves.

## Signers and validation

Required and witnessed owners:

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`
  (`network_compliance`)
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`
  (`ops_and_use_cases`)

Immediately before submission, live `tx-inspect` and `tx-validate` both
exited 0. Validation reported `structurally_clean`, no structural failures,
all 11 spending/reference UTxOs sourced from N2C, and witness completeness 0.
The signed and unsigned transaction IDs match, and their body diff is empty.

Signed-to-signed comparison with invoices #3508, #3516, and #3522 changed
only chain-state/accounting fields: inputs, collateral input, fee, change,
total collateral, and validity upper bound. Beneficiary, amount, asset,
required signers, reference inputs, withdrawal, scripts, and redeemers are
unchanged.

The node accepted the raw signed transaction, and Blockfrost subsequently
reported it in block 13,863,215 with `valid_contract: true`. Blockfrost's
submitted CBOR is byte-identical to the locally archived `signed-tx.hex`.

## Provenance and archived files

- `amaru-treasury-tx` 0.2.21.1
- `tx-inspect`, `tx-validate`, and `tx-diff` 0.2.3.0
- `intent.json`, `wizard.log`, `build.log`, and `report.json`
- `tx.cbor` and `tx.envelope.json` — refreshed unsigned body
- `signed-tx.hex` and `signed-tx.tx` — submitted signed transaction
- two detached witness envelopes
- `tx-inspect.paths.txt`, `tx-validate.json`, `tx-diff.md`, and
  `pre-submit-brief.md`
- `submit.log` and `submitted.json`
- `inputs/*.cbor` — all 11 unique spend, collateral, and reference parent
  transactions, fetched from Blockfrost and body-hash verified

The earlier expired unsigned body remains archived separately at
`2026-08-21-disburse-cyber-castellum-august-2026/`.
