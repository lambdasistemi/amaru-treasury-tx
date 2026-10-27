#!/usr/bin/env bash
set -euo pipefail
R=/tmp/attx-cyber-october-20261026-indexer
B=/nix/store/jmzb7cdl27j4mfirvhszj3pc2ivi3d3y-amaru-treasury-tx-0.2.21.2/bin/amaru-treasury-tx
export CARDANO_NODE_SOCKET_PATH=/srv/prod-hot/cardano/mainnet/ipc/node.socket
"$B" --version > "$R/version.txt"
"$B" --indexer-url http://172.19.0.26:8080 --network mainnet disburse-wizard \
  --scope network_compliance --unit usdm --amount 18750000000 \
  --beneficiary-addr addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl \
  --validity-hours 48 \
  --wallet-addr addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz \
  --metadata /code/amaru-treasury/journal/2026/metadata.json \
  --out "$R/intent.json" --log "$R/wizard.log" \
  --destination-label "Crypto Accounting Group" \
  --description "Pay 18750 USDM to CAG for Cyber Castellum October 2026." \
  --justification "Acceptance of the Cyber Castellum October 2026 cycle review." \
  --label "Pay USDM" \
  --extra-signer f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e \
  --reference-uri ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga --reference-type Other --reference-label "Contract - CRYPTO ACCOUNTING GROUP" \
  --reference-uri ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm --reference-type Other --reference-label "Address-of-record proof - CRYPTO ACCOUNTING GROUP" \
  --reference-uri ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da --reference-type Other --reference-label "Contract - CYBER CASTELLUM CORPORATION" \
  --reference-uri ipfs://bafybeie2okzkrbyrant3dzkjoxwlmuca6hy6ica7vjx5qzxc6mcrof2sqe --reference-type Other --reference-label "Invoice #3546 - CYBER CASTELLUM CORPORATION" \
  --reference-uri ipfs://bafybeibccytawcc72vvgihgvh77jdtiznha4b2zsxix4arsjqjuupkuz7e --reference-type Other --reference-label "October2026 cycle review - CYBER CASTELLUM CORPORATION" \
  > "$R/wizard.stdout.log" 2> "$R/wizard.stderr.log"
"$B" --indexer-url http://172.19.0.26:8080 --network mainnet tx-build --intent "$R/intent.json" --out "$R/unsigned-tx.hex" \
  --report "$R/report.json" --log "$R/build.log" > "$R/build.stdout.log" 2> "$R/build.stderr.log"
"$B" envelope-tx < "$R/unsigned-tx.hex" > "$R/unsigned-tx.tx"
