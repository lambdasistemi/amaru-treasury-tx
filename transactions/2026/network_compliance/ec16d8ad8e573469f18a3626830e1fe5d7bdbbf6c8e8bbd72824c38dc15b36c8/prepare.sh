#!/usr/bin/env bash
set -euo pipefail
cd /code/amaru-treasury-tx-cc-september-rebuild-20260930
ATT_X_RUN=${1:-/tmp/attx-cyber-september-20260930-rebuild}
if [ -e "$ATT_X_RUN/intent.json" ] || [ -e "$ATT_X_RUN/unsigned-tx.hex" ]; then
  echo 'Use a fresh run directory; existing artifacts are immutable.' >&2
  exit 1
fi
mkdir -p "$ATT_X_RUN"
ATT_X_BIN=/nix/store/jhxamwzqjf3gdwf71ka9b2m25m1fimbw-amaru-treasury-tx-0.2.21.2-with-ca/bin/amaru-treasury-tx
ATT_X_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/amaru-treasury-tx/operator.json
# The configured /code socket is superseded by the live production
# socket used by the previous invoice build; mainnet magic is checked.
export CARDANO_NODE_SOCKET_PATH=/srv/prod-hot/cardano/mainnet/ipc/node.socket
"$ATT_X_BIN" --version > "$ATT_X_RUN/version.txt"
scripts/build-september-cc-disburse.sh \
  --binary "$ATT_X_BIN" \
  --wallet-addr "$(jq -r .walletAddress "$ATT_X_CONFIG")" \
  --extra-signer "$(jq -r .scopeOwners.full.ops_and_use_cases "$ATT_X_CONFIG")" \
  --metadata "$(jq -r .metadataPath "$ATT_X_CONFIG")" \
  --out "$ATT_X_RUN" \
  --exec > "$ATT_X_RUN/wizard.stdout.log" 2> "$ATT_X_RUN/wizard.stderr.log"
"$ATT_X_BIN" --network mainnet tx-build \
  --intent "$ATT_X_RUN/intent.json" \
  --out "$ATT_X_RUN/unsigned-tx.hex" \
  --report "$ATT_X_RUN/report.json" \
  --log "$ATT_X_RUN/build.log" \
  > "$ATT_X_RUN/build.stdout.log" 2> "$ATT_X_RUN/build.stderr.log"
"$ATT_X_BIN" envelope-tx \
  < "$ATT_X_RUN/unsigned-tx.hex" \
  > "$ATT_X_RUN/unsigned-tx.tx"
