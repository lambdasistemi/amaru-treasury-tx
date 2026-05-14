#!/usr/bin/env bash
# scripts/smoke/swap-quote-live-usdm.sh — operator-side live smoke
# for the derived `coingecko-ada-usdm` quote source.
#
# Runs `swap-quote --price-source coingecko-ada-usdm` end-to-end
# against the configured live node socket and the public CoinGecko
# endpoint, then re-derives the ADA/USDM rate from the recorded
# components to prove the composition is `(ADA/USD) / (USDM/USD)`.
#
# This script is NOT part of `just ci`. The CoinGecko public API
# rate-limits aggressively, so it is invoked manually by the
# operator before promoting a release.
#
# Required env:
#   CARDANO_NODE_SOCKET_PATH   socket of a synced mainnet/preview node
#   WALLET_ADDR                bech32 wallet address (fuel + collateral)
#   METADATA                   path to a local journal/2026 metadata.json
#
# Optional env:
#   AMARU_TREASURY_TX_EXE      path to the executable (default: build it)
#   SCOPE                      treasury scope (default: network_compliance)
#   USDM                       target USDM amount (default: 1)
#   SLIPPAGE_BPS               slippage policy (default: 100)
#   OUT_DIR                    output dir (default: ./swap-quote-live-out)
#
# Exits 0 if the recorded components agree with `quote.value` within
# 1e-9; non-zero otherwise.

set -euo pipefail

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    printf 'swap-quote-live-usdm: required env %s is unset\n' "$name" >&2
    exit 2
  fi
}

require_env CARDANO_NODE_SOCKET_PATH
require_env WALLET_ADDR
require_env METADATA

SCOPE="${SCOPE:-network_compliance}"
USDM="${USDM:-1}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-100}"
OUT_DIR="${OUT_DIR:-./swap-quote-live-out}"

if [ -z "${AMARU_TREASURY_TX_EXE:-}" ]; then
  cabal build exe:amaru-treasury-tx -O0 >/dev/null
  AMARU_TREASURY_TX_EXE="$(cabal list-bin exe:amaru-treasury-tx -O0)"
fi

mkdir -p "$OUT_DIR"

printf 'swap-quote-live-usdm: running swap-quote with --price-source coingecko-ada-usdm\n' >&2
"$AMARU_TREASURY_TX_EXE" \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  swap-quote \
    --wallet-addr "$WALLET_ADDR" \
    --metadata "$METADATA" \
    --scope "$SCOPE" \
    --usdm "$USDM" \
    --split 1 \
    --price-source coingecko-ada-usdm \
    --slippage-bps "$SLIPPAGE_BPS" \
    --description "swap-quote-live-usdm smoke" \
    --justification "Operator-side verification of the derived ADA/USDM source" \
    --destination-label "smoke" \
    --out-dir "$OUT_DIR"

params="$OUT_DIR/params.json"
if [ ! -f "$params" ]; then
  printf 'swap-quote-live-usdm: missing %s\n' "$params" >&2
  exit 1
fi

derived_value="$(jq -r '.quote.value' "$params")"
ada_usd_value="$(jq -r '.quote.provenance.components[0].value' "$params")"
usdm_usd_value="$(jq -r '.quote.provenance.components[1].value' "$params")"

printf 'swap-quote-live-usdm: derived=%s adaUsd=%s usdmUsd=%s\n' \
  "$derived_value" "$ada_usd_value" "$usdm_usd_value" >&2

# Reconstruct: derived * usdmUsd should equal adaUsd within 1e-9.
diff="$(awk -v d="$derived_value" -v u="$usdm_usd_value" -v a="$ada_usd_value" \
  'BEGIN { x = d * u - a; if (x < 0) x = -x; print x }')"

ok="$(awk -v x="$diff" 'BEGIN { print (x < 1e-9) ? "yes" : "no" }')"
if [ "$ok" != "yes" ]; then
  printf 'swap-quote-live-usdm: composition check failed: |derived*usdmUsd - adaUsd| = %s\n' \
    "$diff" >&2
  exit 1
fi

printf 'swap-quote-live-usdm: OK (derived * usdmUsd within %s of adaUsd)\n' "$diff"
