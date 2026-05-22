# Changelog

All notable changes to `amaru-treasury-tx` are documented here.

## Unreleased

### Features

* **disburse-wizard:** document `--reference-uri`, `--reference-type`, and `--reference-label` for on-chain rationale audit chains backed by IPFS references.

* **transactions:** record May 2026 18 750 USDM disburse from `network_compliance` to Crypto Accounting Group (CAG payee) benefiting Cyber Castellum Corporation, submitted on mainnet as txId [`c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78`](https://cardanoscan.io/transaction/c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78) with the 5-reference Principle VIII v2 evidence set (#202).

* **transactions:** record May 2026 `network_compliance` USDM-consolidation reorganize batch-01 (preparing the Antithesis disburse), submitted on mainnet as txId [`cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba`](https://cardanoscan.io/transaction/cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba) — 10 of 54 treasury UTxOs consolidated into one (71 886.81 USDM + 26.29 ADA); validator-enforced value conservation (#202).

* **transactions:** record reorganize batch-02 (continuing the consolidation), submitted on mainnet as txId [`019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503`](https://cardanoscan.io/transaction/019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503) — 10 more UTxOs (including the batch-01 leftover) consolidated into one (162 071.81 USDM + 48.95 ADA); treasury count 45 → 36 (#202).

### Bug Fixes

* **disburse-wizard:** USDM disburses now keep the full treasury input lovelace on the leftover output and source the beneficiary's min-UTxO deposit from the wallet, restoring the on-chain treasury validator's lovelace-conservation invariant (parity with the bash recipe) (#215)

* **constitution:** amend Principle VIII v2 — payee+beneficiary model with payee on-chain address bound to `vendors.yaml`; introduces 4-doc minimum evidence set (5 with cycle review) when payee ≠ beneficiary (#210)
* **registry:** add `vendors.yaml` at repository root as the source of truth for vendor canonical legal names, jurisdictions, roles, and payee on-chain addresses (#210)
* **transactions:** add `transactions/2026/network_compliance/may-references.json` — May 2026 disburse-reference manifest under Principle VIII v2 (Crypto Accounting Group payee, Cyber Castellum + Antithesis beneficiaries) (#201)

## [0.2.12.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.11.0...v0.2.12.0) (2026-05-21)

### Features

* **intent:** add seven init sub-action variants (#157) ([1da56b5](https://github.com/lambdasistemi/amaru-treasury-tx/commit/1da56b5b420a2513d42b13deee2a31e10ad0fe75))
* **build:** dispatch registry-init sub-action intents (#157) ([1f7bf03](https://github.com/lambdasistemi/amaru-treasury-tx/commit/1f7bf039c82a91294842e8f3d8d7d1630641e093))
* **build:** dispatch stake-reward-init sub-action intents (#157) ([ec34840](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ec3484041a48303aa3e39cafc1440d747bdc7d1d))
* **build:** dispatch governance-withdrawal-init sub-action intents (#157) ([835cbcd](https://github.com/lambdasistemi/amaru-treasury-tx/commit/835cbcdb87791eaca73db144d9b26d6f565d581a))
* **build:** reject non-devnet networks for init intents (#157) ([c4893a5](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c4893a58d7b037ae4ed420fb12407e71728c4073))
* **cli:** scaffold registry-init-wizard parser (#158) ([d42f723](https://github.com/lambdasistemi/amaru-treasury-tx/commit/d42f7230fe02e2e608d30b5066338c004ad4e336))
* **tx:** registry-init-wizard seed-split + devnet guard (#158) ([0e75acf](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0e75acf9f24c69da0b5e696f284c4ff2fb4dae57))
* **tx:** registry-init-wizard mint (#158) ([425f12d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/425f12d403dbfeb19f5ba746b2aee6bf52accd18))
* **tx:** registry-init-wizard reference-scripts (#158) ([8079260](https://github.com/lambdasistemi/amaru-treasury-tx/commit/8079260f7b01cee7658e1fe4805715ed441f4c24))
* **cli:** scaffold stake-reward-init-wizard parser (#159) ([2187032](https://github.com/lambdasistemi/amaru-treasury-tx/commit/2187032e3ce185b7f066a11462d60536c75ddd61))
* **tx:** stake-reward-init-wizard script-account + devnet guard (#159) ([acdd2e2](https://github.com/lambdasistemi/amaru-treasury-tx/commit/acdd2e26e9f4e67986bfde58b7bb8384096b31b2))
* **tx:** stake-reward-init-wizard plain-account (#159) ([61ce09e](https://github.com/lambdasistemi/amaru-treasury-tx/commit/61ce09efdb290fa1466d6d85ec6e29634e5a58c5))
* **cli:** governance-withdrawal-init-wizard (#160) (#169) ([02e56ef](https://github.com/lambdasistemi/amaru-treasury-tx/commit/02e56ef1a32850342b10be86dcc6720c1785c2ed))
* **cli:** fresh DevNet registry bootstrap mode (#175) ([ae18b22](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ae18b22606b8380f9a9cdb15a0fefb3511fc732a))
* **smoke:** add DevNet CLI smoke host and vault preflight (#161) ([5ad2838](https://github.com/lambdasistemi/amaru-treasury-tx/commit/5ad28389befacdadd71936ee7944e285c7bf25d9))
* **smoke:** drive registry and stake bootstrap via CLI (#161) ([aaccc34](https://github.com/lambdasistemi/amaru-treasury-tx/commit/aaccc343305d686dde70304edd911eb9b97522bd))
* **smoke:** live CLI registry-stake bootstrap + chain assertions (#161) ([542d7c3](https://github.com/lambdasistemi/amaru-treasury-tx/commit/542d7c37d2b7ec2e4f59ba7ff9492c18cca57aae))
* **smoke:** extend CLI devnet smoke through governance withdrawal ([ebc83c5](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ebc83c5fffeee0e3c3de34cb3c2c291c45467322))
* **smoke:** verify CLI disburse after materialization (#161) ([84b6cad](https://github.com/lambdasistemi/amaru-treasury-tx/commit/84b6cad3815f355f66a39614354240511a0a4c26))
* **transactions:** historical log directory for wizard + tx-build artifacts (#172) ([d81e106](https://github.com/lambdasistemi/amaru-treasury-tx/commit/d81e1063be02d2040e2505358aa4987f196b1450))
* **transactions:** backfill 55 historical network_compliance USDM swaps (#174) ([9ebef9f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9ebef9f3b92c80c1fd4603a1f2bedbe154cad61f))
* **transactions:** recover 1 intent.json from /tmp scratch (#174) ([415e7e6](https://github.com/lambdasistemi/amaru-treasury-tx/commit/415e7e6fc012221fcc1184044f5edf8cc73c7c94))
* **transactions:** log 2 pending rebuilt txs awaiting signatures (#174) ([ed9c4bf](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ed9c4bf47b7ff8ff0598513e6c466bf1c5b820aa))
* **transactions:** swap-cancel a8bab7bf submitted on-chain (#174) ([7988acf](https://github.com/lambdasistemi/amaru-treasury-tx/commit/7988acfce1206a882565bd2e377f797efdaf0064))
* **transactions:** archive submitted txs after 205k disburse (#174) ([26752c2](https://github.com/lambdasistemi/amaru-treasury-tx/commit/26752c271db743f2f71c0d44b42c501fb532db4a))

### Bug Fixes

* **docs:** use absolute URL for README link from mkdocs page ([dfc9ae4](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dfc9ae4b35fb49e182a4f18c2a98c33e7172d05e))

## [0.2.11.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.10.0...v0.2.11.0) (2026-05-16)

### Features

* **cli:** add --version flag and update-available banner (#141) ([b390a3c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/b390a3c0cc63b9c077c9f8bd0a68f49edbb8dc38))

## [0.2.10.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.9.0...v0.2.10.0) (2026-05-16)

### Features

* **vault:** support addr_xsk imports ([43f8c2d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/43f8c2d31b27190386542ad45c639c504a80a7b8))
* **tx-build:** validate final transactions with tx-tools ([1f47e4a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/1f47e4a7fce2528eeda82159d743dbdc22ffcf71))

### Bug Fixes

* **139:** emit "disburse" event for emergency top-up ([821be2f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/821be2f4ad79309cff7aca2182f983a605785094))

## [0.2.9.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.8.0...v0.2.9.0) (2026-05-15)

### Features

* support local devnet network identity ([dd07666](https://github.com/lambdasistemi/amaru-treasury-tx/commit/dd07666f09ffb80f7d4e28daddaafc9abe5d72f9))
* **withdraw:** use provider reward queries ([bd7fa4f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/bd7fa4f9c4e083d74d7c426be97706c3a6432883))
* add swap-wizard all-ada mode (#130) ([e30fe5f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/e30fe5f3a93e4624a99a7c32ca4fa2722bbeb434))
* **128:** add age-backed vault witness flow ([e3f0d3b](https://github.com/lambdasistemi/amaru-treasury-tx/commit/e3f0d3b1372a9f6428d53b654b4b85e889be8ad2))

### Bug Fixes

* **rebase:** adapt withdraw resolver stub ([e358604](https://github.com/lambdasistemi/amaru-treasury-tx/commit/e358604e76816c3dda7cde5f98e7e8818b2ef0cb))
* **report:** avoid public explorer links for devnet ([9b74732](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9b74732a1dba9eeec602cdcee48ae043ab85f94e))

## [0.2.8.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.7.1...v0.2.8.0) (2026-05-14)

### Features

* **116:** add explicit sundaeswap order cancel command ([ae215aa](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ae215aa4de4dd483d90eccc8be444acbd3f9eed9))
* **116:** require at least two owners for swap cancels ([38a4789](https://github.com/lambdasistemi/amaru-treasury-tx/commit/38a478900ccf046beaae945d41201566e03baeff))
* **117:** add emergency top-up command ([27bcfbd](https://github.com/lambdasistemi/amaru-treasury-tx/commit/27bcfbddeb85f67a5194571b60d7f3d38b80e2d1))

### Bug Fixes

* **116:** centralize sundaeswap order constants ([feb7e82](https://github.com/lambdasistemi/amaru-treasury-tx/commit/feb7e82b9479b71f4430372ab7e4b9a0baafa56d))
* **116:** default sundaeswap order script ref on mainnet ([1cf92b2](https://github.com/lambdasistemi/amaru-treasury-tx/commit/1cf92b2bf82bc5bbf4664971e93c963933e84cc9))
* **117:** finalize emergency top-up wizard fee target ([48f6c82](https://github.com/lambdasistemi/amaru-treasury-tx/commit/48f6c827225ef13cda922a41d8c140f06525cc90))

## [0.2.7.1](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.7.0...v0.2.7.1) (2026-05-14)

### Bug Fixes

* **109:** UTF-8-safe treasury-inspect output under any locale ([a3b3004](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a3b3004af12d508a7a92bc0c5ad45ac23a6e61e4))

## [0.2.7.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.6.0...v0.2.7.0) (2026-05-14)

### Features

* **109:** parse SundaeSwap order datum into ParsedSwapOrder ([12767e7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/12767e72a33dfedd36d569b940b793c1e40c6fb4))
* **109:** treasury-inspect report assembly + JSON/human render + golden ([774aefc](https://github.com/lambdasistemi/amaru-treasury-tx/commit/774aefca2f500b23fdd198eea979e20c58d11192))
* **109:** treasury-inspect JSON Schema + schema-check gate ([79e4ca0](https://github.com/lambdasistemi/amaru-treasury-tx/commit/79e4ca0e06bb4cf3c7c600299c6308cee65bf7e1))
* **109:** treasury-inspect CLI + N2C glue + smoke ([826dd36](https://github.com/lambdasistemi/amaru-treasury-tx/commit/826dd36fd962e4e79e4ad1d922e232d85b21dbf9))

## [0.2.6.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.5.1...v0.2.6.0) (2026-05-14)

### Features

* **110:** derived quote provenance type and audit encoder ([26eff15](https://github.com/lambdasistemi/amaru-treasury-tx/commit/26eff159edb46c45002a39fa927d55d97e855b52))
* **110:** remove live quote retrieval from swap-wizard ([a7bd8a5](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a7bd8a57ae602b0f5052478d0db48d1a522c7053))
* **110:** replace coingecko-ada-usd with derived coingecko-ada-usdm in swap-quote ([0b7a816](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0b7a816bb6d94c048bfa23261902bd916322ff59))
* **106:** envelope-* wrap commands ([f1fb4c4](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f1fb4c4398096f99ab4d688a8f779dce05d78721))
* **106:** de-envelope unwrap command ([bf95e59](https://github.com/lambdasistemi/amaru-treasury-tx/commit/bf95e59f63d44f02be5aefd65c9c28a40ac6d6c7))

### Bug Fixes

* **108:** bare hex txid on submit stdout and stderr ([d05b829](https://github.com/lambdasistemi/amaru-treasury-tx/commit/d05b829df9936286af89a6a31ab9a7203270669c))

## [0.2.5.1](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.5.0...v0.2.5.1) (2026-05-13)

### Bug Fixes

* **102:** accept bare WitVKey alongside [0, WitVKey] envelope ([cc1ef53](https://github.com/lambdasistemi/amaru-treasury-tx/commit/cc1ef53599ec24a0de6646697dcc99d408fb7802))

## [0.2.5.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.4.0...v0.2.5.0) (2026-05-13)

### Features

* **095:** add attach-witness and submit CLI commands ([962795f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/962795f5c315da3b3ed23e9b13f21558c953fd5e))

### Bug Fixes

* **097:** bundle CA store in Linux release artifacts ([b3da20e](https://github.com/lambdasistemi/amaru-treasury-tx/commit/b3da20ed155c088ad8fc106f77b7792f837cbcc6))
* **094:** derive CoinGecko User-Agent from cabal version ([377713f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/377713f635300636f2fb62cfd3ef08488b1defe2))

## [0.2.4.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.3.0...v0.2.4.0) (2026-05-12)

### Features

* **088:** swap-wizard validity follows chain horizon ([14a9ccf](https://github.com/lambdasistemi/amaru-treasury-tx/commit/14a9ccf138474fd6ff5a3ed5e53927c7e460e6ce))
* **088:** disburse-wizard validity follows chain horizon ([0c99c1d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0c99c1defbf2fb20ed60f7a1e60ad4911cb6fdec))
* **088:** withdraw-wizard validity follows chain horizon ([b01c7e2](https://github.com/lambdasistemi/amaru-treasury-tx/commit/b01c7e217fb71df333c986987ccc2682fc5357af))

### Bug Fixes

* **091:** distribute swap-order remainder; no dust outputs ([cafd3a7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/cafd3a71f5a28d66924d86c07e52947ee744dac4))

## [0.2.3.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.2.0...v0.2.3.0) (2026-05-11)

### Operator Notes

* `disburse-wizard` now supports the unified disburse build flow for USDM.
  USDM is the default disbursement unit; ADA remains available with
  `--unit ada`.
* USDM disbursements select treasury inputs for both the requested token
  amount and the ADA deposit needed by beneficiary outputs while preserving
  unrelated assets and leftover value.
* The README and MkDocs operator pages now document the wizard-to-`tx-build`
  flow, the USDM default, and the ADA override.
* `tx-build` reports builder failures through the normalized CLI error path.
* `swap-wizard` only requires wallet fee slack from wallet inputs.

### Maintainer Notes

* CLI dispatch was split into smaller command modules and option parsers.
  Command names and documented user-facing options are preserved.

### Features

* **disburse:** add USDM unified build support ([a99441a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a99441a2efacc1ab9b61803bc3bf5210b1877804))

### Bug Fixes

* **swap-wizard:** require only fee slack from wallet ([7587d20](https://github.com/lambdasistemi/amaru-treasury-tx/commit/7587d205c3fef9fe859e06aca3edca3283d3b7e6))
* **tx-build:** normalize builder failures ([c2ae1aa](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c2ae1aadc76b56390468c65a61c0355fb7f54f33))

## [0.2.2.0](https://github.com/lambdasistemi/amaru-treasury-tx/compare/v0.2.1.1...v0.2.2.0) (2026-05-11)

### Features

* **006:** implement withdraw intent contract ([73b1fce](https://github.com/lambdasistemi/amaru-treasury-tx/commit/73b1fce19cef4ab318876ffebd8679262974f887))
* **006:** pure withdraw-wizard translation ([a0be2c0](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a0be2c0be70022c2620772334237de3486e86966))
* **006:** resolve withdraw wizard environment ([4ccbda1](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4ccbda186c7d6bfb67bd8cffe90bcbee9d86c743))
* **006:** withdraw-wizard CLI runner ([f3d7bad](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f3d7bad7cd7d1783d9cbe78e3378dc56ea87e699))
* **006:** wire live withdraw rewards query ([37d6e92](https://github.com/lambdasistemi/amaru-treasury-tx/commit/37d6e92de2755cf955c2931e167cc4e2648b5d68))
* **006:** typed withdraw zero-rewards result ([5519f8c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/5519f8ca87185fd4aa91a9f2f57b4a7fde93432c))
* **006:** no-op withdraw zero rewards ([99f08bc](https://github.com/lambdasistemi/amaru-treasury-tx/commit/99f08bc45814013f9cb1e21451eee25b45138dc8))
* **006:** wire withdraw build dispatcher ([5ab9364](https://github.com/lambdasistemi/amaru-treasury-tx/commit/5ab93646af6b74b6eff5db72e26f7ec7d5e0f745))
* **006:** implement withdraw runner ([de25174](https://github.com/lambdasistemi/amaru-treasury-tx/commit/de25174bf66bbf130bfc8b4e682142527fc15d83))
* **intent-json:** add wallet extraTxIns field ([4f1cc16](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4f1cc16a8869c71c7427ead672b444ae7251000c))
* **swap-wizard:** accept extra wallet inputs in env ([b3a1fa7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/b3a1fa73eb8eecdac4217c6a9747e5031c6fdaab))
* **swap:** add extra wallet inputs to intent ([77a19aa](https://github.com/lambdasistemi/amaru-treasury-tx/commit/77a19aa5e36a1054bc11279f6932a85b5c8d6cc2))
* **intent-json:** parse extra wallet inputs ([cf435cf](https://github.com/lambdasistemi/amaru-treasury-tx/commit/cf435cf3cf7aa0c0773063d1e261fbb1b9eac0ab))
* **swap-wizard:** emit extra wallet inputs ([abe646c](https://github.com/lambdasistemi/amaru-treasury-tx/commit/abe646c77f50b974d7ade8da915811203dda57fe))
* **swap-wizard:** aggregate wallet fuel inputs ([639170a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/639170a4bf7f628532f1493e518d0db4f0a5001f))
* **swap-wizard:** render wallet shortfalls ([0cc6c04](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0cc6c041ad2f862394a34c31f9cfdc7adb0c3702))
* **072:** establish transaction report contract ([06a1be3](https://github.com/lambdasistemi/amaru-treasury-tx/commit/06a1be30558319feca852db781d4f30d0699dd37))
* **072:** build deterministic transaction reports ([995d17f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/995d17fd31206b4691a931cca65d51467bbfed87))
* **072:** account swap wallet report facts ([34d9b83](https://github.com/lambdasistemi/amaru-treasury-tx/commit/34d9b83478d1dadad16fb96b460ebc1df8d0a205))
* **072:** account swap treasury report facts ([9271cfa](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9271cfa0748d9594e305c3bb230f2d15e68847ba))
* **072:** classify swap report outputs ([9d3e6e0](https://github.com/lambdasistemi/amaru-treasury-tx/commit/9d3e6e0526ce325a9304c550a5efbc186fc40e3d))
* **072:** report signer source requirements ([4cc840a](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4cc840a3ac5bd420512802f455ed31257f72cc73))
* **072:** report validation metadata facts ([50d3577](https://github.com/lambdasistemi/amaru-treasury-tx/commit/50d35775096fb4ee154e6208476b970e200ea602))
* **072:** add tx-build report writer ([942794d](https://github.com/lambdasistemi/amaru-treasury-tx/commit/942794ddaf433f522939447ea5b3220a3e579713))
* **070:** derive quote swap parameters ([fa2762f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/fa2762f5b8e3d74d18aea74ce43af7dc0ae4dab7))
* **070:** add swap quote affordability checks ([6d8f866](https://github.com/lambdasistemi/amaru-treasury-tx/commit/6d8f866a7dc3fe17d46691cccf025dadc8cddcb6))
* **070:** add swap quote audit JSON ([11ecbb7](https://github.com/lambdasistemi/amaru-treasury-tx/commit/11ecbb747a12e1e94f4b29985c7783a4a60cd37b))
* **070:** add swap quote source parser ([ee4b745](https://github.com/lambdasistemi/amaru-treasury-tx/commit/ee4b745557fe8a33d5476bc79c767679b1235959))
* **070:** add swap quote composite runner ([a56ec32](https://github.com/lambdasistemi/amaru-treasury-tx/commit/a56ec320f5fdd99382a9c7d5b3f8fa34167ea82e))
* **report-render:** start specs scaffold for issue #74 ([76d1564](https://github.com/lambdasistemi/amaru-treasury-tx/commit/76d1564994368f3e03b2e31a383cba9525d977d6))
* **report-render:** emit tx-build output envelope ([1d713e6](https://github.com/lambdasistemi/amaru-treasury-tx/commit/1d713e664e1fb66eaa13e65a164cae224e6ab519))
* **report-render:** add pure markdown renderer ([f6a449e](https://github.com/lambdasistemi/amaru-treasury-tx/commit/f6a449e7c5214144933543c0441921b96727c5b6))
* **report-render:** derive validity UTC times ([0c5adf4](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0c5adf4544342854265fe2d0fdd3ddbdc7eeed6f))
* **report-render:** add swap markdown golden ([0419dd5](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0419dd5271ecc3ea570348da7aad480960182f05))
* **report-render:** resolve rendered identities ([4a789fb](https://github.com/lambdasistemi/amaru-treasury-tx/commit/4a789fbc37facbbc459987e360d676cc41117443))
* **report-render:** add pipe-native CLI ([c614352](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c6143529ed0e06a9e6c746747570e3bb75017318))
* **report-render:** add operator review helper ([de7fb57](https://github.com/lambdasistemi/amaru-treasury-tx/commit/de7fb5705c333a93dafc6f8883f1a697e94da8fc))

### Bug Fixes

* **rebase:** adapt to withdraw-wizard merge ([41b48bc](https://github.com/lambdasistemi/amaru-treasury-tx/commit/41b48bc8de8c04e5cabc38c24e915b311a2b36de))
* **tx-build:** include wallet extras in chain-context fetch ([62d8185](https://github.com/lambdasistemi/amaru-treasury-tx/commit/62d81858d2bca4ea68c6b1dc271953f5b751038c))
* **nix:** expose checks as runCommand wrappers around writeShellApplication apps ([46317ad](https://github.com/lambdasistemi/amaru-treasury-tx/commit/46317adb61865e534202a778175544122d470331))
* **008:** fund swap order overhead from treasury ([632020f](https://github.com/lambdasistemi/amaru-treasury-tx/commit/632020f6358545aef2d1924cfabdf006cd9acf7d))
* **070:** derive quote swap amounts from emitted rate ([c4eed14](https://github.com/lambdasistemi/amaru-treasury-tx/commit/c4eed14ec04d72d917d19718e4fbf35a4f974a0e))
* **swap-wizard:** restore quote-derived pipe flow ([652f413](https://github.com/lambdasistemi/amaru-treasury-tx/commit/652f413337c2074f80bcbaa4bd500505def350aa))

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
