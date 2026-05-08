# Changelog

All notable changes to `amaru-treasury-tx` are documented here.

## Unreleased

### Features

* swap-wizard aggregates multiple wallet UTxOs as fuel; intent.json gains optional `wallet.extraTxIns` array ([#65](https://github.com/lambdasistemi/amaru-treasury-tx/issues/65))

## [0.2.1.1](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.1.0...v0.2.1.1) (2026-05-07)

### Bug Fixes

* probe tx-build N2C magic with LSQ ([5019465](https://github.com/lambdasistemi/amaru-treasury-tx/commit/5019465f8fa92f2985a2b4c1e92497734fe7055f))

## [0.2.1.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.0.0...v0.2.1.0) (2026-05-07)

### Features

* **004:** phase 1 — module + test stubs for disburse-wizard ([a89bc21](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a89bc210afa5c550de7e2a806f0386a85d0f076b))
* **004:** route ADA disburse through unified tx-build ([dc8ad18](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dc8ad18a3111920be5314b4b168d67171063a5cb))
* **004:** add disburse treasury selection helpers ([a231507](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a231507a6f183e6298f80a749756181f463d17cd))

## [0.2.0.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.1.1.0...v0.2.0.0) (2026-05-06)

### Breaking Changes

* infer swap-wizard scope owner signer ([78366ff](https://github.com/lambdasistemi/amaru-treasury-tx/commit/78366ff8f0f1cf13d79a611f1f7d98effc4dc319))

### Bug Fixes

* **release:** provide gh on linux publisher (#37) ([cbb910c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/cbb910cc9216b2b95f4144a1afae871d4c9a2c93))
* **release:** reuse only open release PRs ([6abefed](https://github.com/lambdasistemi/amaru-treasury-tx/commit/6abefed741b2451103507a5856fdff371a3daa27))
* **docs:** use mermaid2.fence_mermaid (not _custom) so diagrams render ([ff05d93](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ff05d932740f8a53039691a6d8bee29919240ad9))

## [0.1.1.0](https://github.com/lambdasistemi/amaru-treasury-tx/releases/tag/v0.1.1.0) (2026-05-05)

### Features

* **spec:** treasury transaction CLI (#001) ([29e5a40](https://github.com/lambdasistemi/amaru-treasury-tx/commit/29e5a4035065120e8a489de005b0baf74059fc5d))
* **plan:** treasury transaction CLI plan + Phase 0/1 artifacts (#001) ([c307e4a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c307e4ae9546c711544748f14a58f28a322b2fd3))
* **tasks:** treasury transaction CLI task breakdown (#001) ([01812f0](https://github.com/lambdasistemi/amaru-treasury-tx/commit/01812f0088a5f27489ed4e7825566b538ca02ddf))
* **scaffold:** Phase 1 — nix flake + cabal + justfile + real CI (T001-T010) ([7c2628a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/7c2628aff946da65473ac92afd8f70ba17d6d2c8))
* **lib:** Amaru.Treasury.Scope (T011, T012) ([a855a89](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a855a89c4a173d362b044829f7c8893dc073714f))
* **infra:** release-please + MkDocs site + Pages workflow ([756ea49](https://github.com/lambdasistemi/amaru-treasury-tx/commit/756ea49710743cce46ba01171247dbcc8933e613))
* **lib:** Constants + Metadata parser + fixture (T013-T016) ([11ba820](https://github.com/lambdasistemi/amaru-treasury-tx/commit/11ba820a5647116d6e95dc32e56e14efb2622e4d))
* **lib:** Summary JSON encoder (T026, T027) ([51e31f6](https://github.com/lambdasistemi/amaru-treasury-tx/commit/51e31f68deee47987626a9ac8a96cc6f714cc7a8))
* **lib:** Redeemer ToData (T017, T018) ([ce3abb9](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ce3abb9fc4932fd11d6d63145d10099b81e8be77))
* **lib:** Backend alias + Backend.N2C constructor (T019, T020) ([fb94048](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fb94048262e16cf3304193a103598bcd3e93a5af))
* **lib:** Validity.computeUpperBound (T025) ([681b02b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/681b02b7948d40c64d210833dac56ddecd206664))
* **lib:** UtxoSelect with property tests (T021, T022) ([f28052a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f28052a1e9a801daa5534e218a69860ff101928e))
* **lib:** frozen pparams fixture + loader (T029) ([04c960b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/04c960bc5030e4475d6e40b24d7eb9c0e1c9507f))
* **lib:** LedgerParse helpers (Phase 3 prep) ([dca984c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dca984cbc0903aeef426d18f2c7c1ac862b7a838))
* **lib:** Tx.Withdraw program + structural smoke test ([48c63b8](https://github.com/lambdasistemi/amaru-treasury-tx/commit/48c63b86c8319c5717207317da61c560446d1e4f))
* **lib:** Tx.Disburse program (ADA disburse, US1) ([774469d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/774469d08797bb645f1541785fb09da412a85ebd))
* **lib:** Tx.Swap program (multi-output disburse for swap.sh) ([45f3af8](https://github.com/lambdasistemi/amaru-treasury-tx/commit/45f3af85eddd998f26b43b4597734d17519dbfca))
* **lib:** Amaru.Treasury.AuxData (rationale label 1694) ([6bcfa02](https://github.com/lambdasistemi/amaru-treasury-tx/commit/6bcfa021b1e743f8bade25cd6c98ce5cfd2a19b9))
* **app:** swap-probe — live mainnet parity harness ([a06dbea](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a06dbea056de260f5fc023b8dce8edfc2747d6d6))
* **lib:** ChainContext fixture loader ([8a3e213](https://github.com/lambdasistemi/amaru-treasury-tx/commit/8a3e213ecefdd83fc54269b271a34f929d85097c))
* **release:** macOS Homebrew + Linux AppImage/DEB/RPM ([37fc8b7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/37fc8b756f7fda526eaf4123f29a183bdd06fdaf))
* **release:** workflow_dispatch + uploadable workflow artifacts ([457dbd3](https://github.com/lambdasistemi/amaru-treasury-tx/commit/457dbd32cea7d0d0c00ab93544788e83c8fdf8b8))
* **release:** replace release-please with cabal planner ([ea40990](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ea409904824d3668ce9146cf08955fdc020400a3))
* verify registry anchors from local metadata ([db56c70](https://github.com/lambdasistemi/amaru-treasury-tx/commit/db56c70938cf9ae66aa0ef614b11e4ed4bf86082))
* **002:** swap-wizard MVP — typed answers + pure translation to SwapIntentJSON ([ddc6640](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ddc66400c9b6701e5a6e477892f4db7e4c87923a))
* **002:** swap-wizard subcommand + Provider-IO resolver ([00af152](https://github.com/lambdasistemi/amaru-treasury-tx/commit/00af152403885ee869363aba5ab36036c0224088))
* **002:** human-friendly swap-wizard CLI ([7164f9f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/7164f9fd19191b8b0a2fc8c1d4b27487195c132b))
* **002:** mainnet networkConstants + --chunk-ada + recreate golden ([dd2d89b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dd2d89b5a4e4e4f1803432cd8d967c26c631439f))
* **002:** drop --network; derive name from --network-magic ([97a559b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/97a559bf4659e39e059ab0cfb87347d784b2679b))
* **002:** USDM-as-input + --split rename ([9f8e047](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9f8e0479e5f39450e33f13b5cf8d1c91748751b4))
* **002:** --network NAME as alternative to --network-magic ([e499a54](https://github.com/lambdasistemi/amaru-treasury-tx/commit/e499a542e29fd1097005533bd162c6f41b31ecc3))
* **002:** consume verified local metadata in swap wizard ([574d488](https://github.com/lambdasistemi/amaru-treasury-tx/commit/574d488c5e7ad84abe6ae0ee3a727996680be1a0))
* **002:** tracer-driven step log + non-interactive wizard ([ddbec7e](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ddbec7e588d816723976ffb3dcbcb451059754b2))
* **002:** pipe wizard | swap by defaulting --intent to stdin ([ddf9023](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ddf90238537820151d9b4d80134a4cc6e710a269))
* tracer-driven step log for the swap subcommand ([94cb743](https://github.com/lambdasistemi/amaru-treasury-tx/commit/94cb7433714119246f6b3b3b6a623d8bc5345f3b))

### Bug Fixes

* dead code, Word8 TxIn index, and read(show) test pattern ([8b57a10](https://github.com/lambdasistemi/amaru-treasury-tx/commit/8b57a100fc82977bff7559e95d06ba565f0588fc))
* **003:** query registry anchors by TxIn instead of script address ([104f6ad](https://github.com/lambdasistemi/amaru-treasury-tx/commit/104f6ad25fc17aab159f28d86ba1dec9d3fc62b3))
* **002:** catch IOException in loadRegistry ([dce3e6d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dce3e6d72fae85b1488aa061d164cd48be58d9e7))
* **002:** permissionsRewardAccount + intent.json deployed_at labels ([9db3970](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9db397013191a59346d4158c69a17aa4c3d57a9e))
* **docs:** wire mermaid2 custom fence so diagrams render ([4d7e8bb](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4d7e8bbb4e2c99ab89f9b516b8264edbe4880824))
* **release:** preserve cabal version formatting (#36) ([ff795ba](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ff795ba7eb5c6b55d339f3c53fb2f2c4bb6584b6))

