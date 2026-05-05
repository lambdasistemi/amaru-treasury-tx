# Changelog

## [0.2.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.1.0...v0.2.0) (2026-05-05)


### Features

* **app:** swap-probe — live mainnet parity harness ([a06dbea](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a06dbea056de260f5fc023b8dce8edfc2747d6d6))
* **infra:** release-please + MkDocs site + Pages workflow ([756ea49](https://github.com/lambdasistemi/amaru-treasury-tx/commit/756ea49710743cce46ba01171247dbcc8933e613))
* **lib+app:** ChainContext + SwapBuild driver + swap CLI ([f16558d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f16558d6a8b92e914ce9bdf3989ade191bc964a2))
* **lib+app:** ChainContext fixture loader + capture-swap-context ([12ee84b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/12ee84b4d17ab26f0531d73820a9f8a0deaf3128))
* **lib:** Amaru.Treasury.AuxData (rationale label 1694) ([6bcfa02](https://github.com/lambdasistemi/amaru-treasury-tx/commit/6bcfa021b1e743f8bade25cd6c98ce5cfd2a19b9))
* **lib:** Amaru.Treasury.Scope (T011, T012) ([a855a89](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a855a89c4a173d362b044829f7c8893dc073714f))
* **lib:** Backend alias + Backend.N2C constructor (T019, T020) ([fb94048](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fb94048262e16cf3304193a103598bcd3e93a5af))
* **lib:** ChainContext fixture loader ([8a3e213](https://github.com/lambdasistemi/amaru-treasury-tx/commit/8a3e213ecefdd83fc54269b271a34f929d85097c))
* **lib:** Constants + Metadata parser + fixture (T013-T016) ([11ba820](https://github.com/lambdasistemi/amaru-treasury-tx/commit/11ba820a5647116d6e95dc32e56e14efb2622e4d))
* **lib:** frozen pparams fixture + loader (T029) ([04c960b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/04c960bc5030e4475d6e40b24d7eb9c0e1c9507f))
* **lib:** LedgerParse helpers (Phase 3 prep) ([dca984c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dca984cbc0903aeef426d18f2c7c1ac862b7a838))
* **lib:** Redeemer ToData (T017, T018) ([ce3abb9](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ce3abb9fc4932fd11d6d63145d10099b81e8be77))
* **lib:** Summary JSON encoder (T026, T027) ([51e31f6](https://github.com/lambdasistemi/amaru-treasury-tx/commit/51e31f68deee47987626a9ac8a96cc6f714cc7a8))
* **lib:** Tx.Disburse program (ADA disburse, US1) ([774469d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/774469d08797bb645f1541785fb09da412a85ebd))
* **lib:** Tx.Swap program (multi-output disburse for swap.sh) ([45f3af8](https://github.com/lambdasistemi/amaru-treasury-tx/commit/45f3af85eddd998f26b43b4597734d17519dbfca))
* **lib:** Tx.Withdraw program + structural smoke test ([48c63b8](https://github.com/lambdasistemi/amaru-treasury-tx/commit/48c63b86c8319c5717207317da61c560446d1e4f))
* **lib:** UtxoSelect with property tests (T021, T022) ([f28052a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f28052a1e9a801daa5534e218a69860ff101928e))
* **lib:** Validity.computeUpperBound (T025) ([681b02b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/681b02b7948d40c64d210833dac56ddecd206664))
* **plan:** treasury transaction CLI plan + Phase 0/1 artifacts ([#001](https://github.com/lambdasistemi/amaru-treasury-tx/issues/001)) ([c307e4a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c307e4ae9546c711544748f14a58f28a322b2fd3))
* **release:** macOS Homebrew + Linux AppImage/DEB/RPM ([37fc8b7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/37fc8b756f7fda526eaf4123f29a183bdd06fdaf))
* **release:** workflow_dispatch + uploadable workflow artifacts ([457dbd3](https://github.com/lambdasistemi/amaru-treasury-tx/commit/457dbd32cea7d0d0c00ab93544788e83c8fdf8b8))
* **scaffold:** Phase 1 — nix flake + cabal + justfile + real CI (T001-T010) ([7c2628a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/7c2628aff946da65473ac92afd8f70ba17d6d2c8))
* **spec:** treasury transaction CLI ([#001](https://github.com/lambdasistemi/amaru-treasury-tx/issues/001)) ([29e5a40](https://github.com/lambdasistemi/amaru-treasury-tx/commit/29e5a4035065120e8a489de005b0baf74059fc5d))
* **tasks:** treasury transaction CLI task breakdown ([#001](https://github.com/lambdasistemi/amaru-treasury-tx/issues/001)) ([01812f0](https://github.com/lambdasistemi/amaru-treasury-tx/commit/01812f0088a5f27489ed4e7825566b538ca02ddf))


### Bug Fixes

* dead code, Word8 TxIn index, and read(show) test pattern ([8b57a10](https://github.com/lambdasistemi/amaru-treasury-tx/commit/8b57a100fc82977bff7559e95d06ba565f0588fc))

## Changelog

All notable changes to `amaru-treasury-tx` are documented here.

## Unreleased

- Bootstrap the project: nix flake (haskell.nix + IOG cache),
  cabal.project pinning [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  at commit `8cc0605`, justfile, real CI replacing the stub Build Gate.
