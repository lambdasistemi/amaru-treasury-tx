# Cyber Castellum August 2026 disbursement

- **status:** expired unsigned build; preserved as historical context
- **predicted txid:** `c1280e96ad626cb5768674e5cba8be1cacf88ef24514bd1bce104af7b1eb7ee8`
- **scope:** `network_compliance`
- **event:** `disburse`
- **amount:** 18,750 USDM
- **beneficiary:** Crypto Accounting Group, the established Cyber Castellum payee
- **invoice:** Cyber Castellum invoice #3528, dated 2026-08-07, for the
  2026-07-01 through 2026-07-31 billing period (Milestone 4)
- **acceptance:** August 2026 cycle review, accepted 2026-08-07

This body's validity window closed before its witness round completed. It was
not submitted. A refreshed sibling was subsequently signed and submitted as
`4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4`.

## Intent and approval evidence

The transaction pays the same beneficiary address used by the three prior
Cyber Castellum disbursements (invoices #3508, #3516, and #3522):

`addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`

The invoice and acceptance record are pinned in the transaction metadata:

- `Invoice #3528 - Amaru.pdf`
  - IPFS: `ipfs://QmNQbjmE6B9JvqwrHX4JVnCepqGoVhDpGQuwaSUjwDeP9f`
  - SHA-256: `1cb3814924844626bb78dd2a08a2e88b21ebf1651ef5681a0d07681a199508a4`
- `2026_08_07_Amaru_Monthly_White_hacking.pdf`
  - IPFS: `ipfs://QmXGGFgD5vt1awuP3ttGgAwL4Rm2CYEuVgFkycgGwmi2xh`
  - SHA-256: `2f9d3b9cbc2356f0f16f42a699e5bba7e650c2c7fdafaab7743d627eb138a954`

Pinata's pin-list API confirmed one pinned record for each CID. During the
later refresh, both documents were publicly retrieved from IPFS and their
SHA-256 values matched those recorded above. The three common contract and
address-proof references were also publicly retrieved.

## Transaction accounting

- Treasury inputs: 18,998.542293 USDM and 139.235155 ADA across six UTxOs.
- Beneficiary output: 18,750 USDM and 1.189560 ADA.
- Treasury leftover: 248.542293 USDM and 138.045595 ADA.
- Wallet input/collateral: `57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519#9`.
- Wallet change: 75.882751 ADA.
- Fee: 0.975732 ADA.
- Total collateral: 1.463598 ADA.
- Validity upper bound: slot `195823578` (2026-08-22T09:11:09Z).
- Body size: 2,655 bytes.
- CIP-1694 auxiliary-data hash:
  `0d15de7b437dac89a1e67dbe368d5b98dd997fe62e32286224f734ed7dae8d5a`.

Required owners:

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`
  (`network_compliance`, selected scope owner)
- `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`
  (extra owner signer)

No witness files are present in this build-time archive.

## Build and validation

The accepted build used `amaru-treasury-tx` v0.2.21.1 from its official
portable release (AppImage SHA-256
`cf981fdb03414f262b6e51b098191004cb987a86fc640e8a7c9ac235d0aa1338`).
An initial 48-hour intent was rejected before transaction construction because
its validity upper bound exceeded the node's known era-history horizon. The
fresh sibling build used a 24-hour validity window and succeeded with seven
redeemers and zero failures.

Independent inspection used `tx-inspect` v0.2.3.0 with the repository's Amaru
rules and a live mainnet node. Independent validation used `tx-validate`
v0.2.3.0 against the same node and returned exit 0,
`status: structurally_clean`, no structural failures, and live `n2c` sources
for protocol parameters, slot, reward accounts, and all eleven queried UTxOs.
The unsigned transaction has the expected missing-witness count; both owners
listed above must witness it before any submission can be considered.

## Archived files

- `intent.json` — immutable wizard intent.
- `tx.cbor` — unsigned transaction CBOR hex.
- `tx.envelope.json` — unsigned text envelope.
- `wizard.log`, `build.log`, and `report.json` — build provenance and report.
- `tx-inspect.paths.txt` and `tx-validate.json` — independent validation
  evidence captured against the live mainnet node.
